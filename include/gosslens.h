/*
 * Gosslens C ABI.
 *
 * This header is the one boundary between the core and every SDK. It is
 * hand-written, versioned, and frozen per minor release: within a major
 * version symbols and struct layouts are only ever appended, never changed
 * or reordered. The abi gate diffs this surface on every change.
 *
 * Conventions:
 *   - Every symbol is prefixed goss_.
 *   - Handles are opaque. Creation returns ownership; goss_*_destroy releases
 *     it. A destroy call accepts null and does nothing.
 *   - Functions that can fail return goss_status. No errno, no exceptions.
 *   - Descriptor structs are plain data with fixed layouts, documented and
 *     static-asserted byte for byte.
 *
 * Threading:
 *   - An engine and its sessions are confined to the thread that created
 *     them, called the graph thread, unless a function is marked any-thread.
 *   - goss_abi_version is any-thread and must be the first call an SDK makes;
 *     a major mismatch means the SDK must refuse to run.
 */

#ifndef GOSSLENS_H
#define GOSSLENS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GOSS_ABI_MAJOR 0u
#define GOSS_ABI_MINOR 172u
#define GOSS_ABI_VERSION ((GOSS_ABI_MAJOR << 16) | GOSS_ABI_MINOR)

/* Any-thread. Compare the high 16 bits against GOSS_ABI_MAJOR. */
uint32_t goss_abi_version(void);

/* Which capabilities this build compiled real, as GOSS_CAP_* bits. The stub
 * and full libraries share a filename and an abi version, so this is how a
 * consumer tells them apart before feeding real bytes to an enable op. */
#define GOSS_CAP_TRACKING (1ull << 0)
#define GOSS_CAP_SEGMENTATION (1ull << 1)
#define GOSS_CAP_ML_INFER (1ull << 2)
#define GOSS_CAP_DIFFUSION (1ull << 3)
#define GOSS_CAP_BEAUTY (1ull << 4)
#define GOSS_CAP_PHYSICS (1ull << 5)
#define GOSS_CAP_VIDEO_TEXTURES (1ull << 6)
#define GOSS_CAP_PHOTO_CAPTURE (1ull << 7)
#define GOSS_CAP_RECORDING (1ull << 8)
#define GOSS_CAP_FILE_IO (1ull << 9)

/* Any-thread. */
uint64_t goss_capabilities(void);

/* Any-thread. Scratch allocation inside the module for embedders that
 * cannot address its memory directly, the wasm host in particular. Free
 * with the same size. */
void *goss_alloc(size_t size);
void goss_free(void *ptr, size_t size);

typedef enum goss_status {
    GOSS_OK = 0,
    GOSS_ERROR_INVALID_ARGUMENT = 1,
    GOSS_ERROR_OUT_OF_MEMORY = 2,
    GOSS_ERROR_POOL_EXHAUSTED = 3,
    GOSS_ERROR_ABI_MISMATCH = 4,
    GOSS_ERROR_RENDERER_UNAVAILABLE = 5,
    GOSS_ERROR_UNSUPPORTED = 6,
    GOSS_AGAIN = 7,
    /* A lens is live but a node the manifest did not mark optional could not do
     * what it asked. The rest of the lens draws; the node reports say which node
     * and why, so the host decides whether that is acceptable. */
    GOSS_LENS_NODE_FAILED = 8,
    /* The session's scope does not carry the verb this op needs. Distinct from
     * GOSS_UNSUPPORTED on purpose: a host can grant this one, and no amount of
     * asking changes the other. */
    GOSS_OUT_OF_SCOPE = 9,
} goss_status;

typedef struct goss_engine goss_engine;
typedef struct goss_session goss_session;

/* How the pipeline is currently degraded. Levels only trade effect quality;
 * capture and preview never stop. */
/* What the engine is currently doing, not a label it reports. FULL runs
 * every analysis every frame; REDUCED_ML_CADENCE every other frame, reusing
 * the last result between; SEGMENTATION_OFF stops feeding the segmenter, so
 * mask channels take their zero-mask behaviour; BEAUTY_SIMPLIFIED keeps
 * smoothing and tone; PASSTHROUGH draws the camera straight through. */
typedef enum goss_degrade_level {
    GOSS_DEGRADE_FULL = 0,
    GOSS_DEGRADE_REDUCED_ML_CADENCE = 1,
    GOSS_DEGRADE_SEGMENTATION_OFF = 2,
    GOSS_DEGRADE_BEAUTY_SIMPLIFIED = 3,
    GOSS_DEGRADE_PASSTHROUGH = 4,
} goss_degrade_level;

/* Platform thermal pressure, fed by the SDK from the OS thermal API. */
typedef enum goss_thermal {
    GOSS_THERMAL_NOMINAL = 0,
    GOSS_THERMAL_FAIR = 1,
    GOSS_THERMAL_SERIOUS = 2,
    GOSS_THERMAL_CRITICAL = 3,
} goss_thermal;

/* Pixel layout of a camera frame as delivered by the platform. */
typedef enum goss_pixel_format {
    GOSS_PIXEL_NV12 = 0,
    GOSS_PIXEL_NV21 = 1,
    GOSS_PIXEL_I420 = 2,
    GOSS_PIXEL_BGRA8 = 3,
    GOSS_PIXEL_RGBA8 = 4,
} goss_pixel_format;

typedef enum goss_color_standard {
    GOSS_COLOR_BT601 = 0,
    GOSS_COLOR_BT709 = 1,
    GOSS_COLOR_BT2020 = 2,
} goss_color_standard;

typedef enum goss_color_range {
    GOSS_COLOR_RANGE_VIDEO = 0,
    GOSS_COLOR_RANGE_FULL = 1,
} goss_color_range;

/* goss_frame_desc.flags bits. Rotation is the quarter-turn count to apply for
 * upright display; mirror flips horizontally, for front cameras. */
#define GOSS_FRAME_FLAG_MIRROR 0x1u
#define GOSS_FRAME_ROTATION_SHIFT 8u
#define GOSS_FRAME_ROTATION_MASK 0x300u

/* Describes one camera frame. The pixel data itself stays in the platform
 * buffer the SDK hands over; the core never copies it on the frame path.
 * Layout: 32 bytes, static-asserted below. */
typedef struct goss_frame_desc {
    uint32_t width;
    uint32_t height;
    uint32_t pixel_format;   /* goss_pixel_format */
    uint32_t color_standard; /* goss_color_standard */
    uint32_t color_range;    /* goss_color_range */
    uint32_t flags;          /* GOSS_FRAME_* bits */
    int64_t timestamp_us;    /* capture time, monotonic microseconds */
} goss_frame_desc;

/* The render surface an SDK hands the engine: an NSWindow, CAMetalLayer,
 * ANativeWindow, or canvas handle per platform. Layout: 16 bytes on 64-bit
 * targets, 12 on wasm32. */
typedef struct goss_renderer_desc {
    void *native_window_handle;
    uint32_t width;
    uint32_t height;
} goss_renderer_desc;

/* Zero-copy plane handles for one frame: platform texture objects
 * (MTLTexture, AHardwareBuffer-backed images, WebGL textures) as opaque
 * pointer-sized values. The platform object must stay valid until the next
 * submitted frame has rendered; the SDK guarantees that by holding the
 * buffer. Layout: 32 bytes. */
typedef struct goss_frame_planes {
    uint32_t plane_count;
    uint32_t reserved; /* zero */
    uint64_t planes[3];
} goss_frame_planes;

/* A tracking result crossing the boundary. Points are x, y, z triples in
 * normalized image space; the memory belongs to the producer and stays
 * valid only for the duration of the callback or call it is passed to.
 * Layout: 24 bytes, static-asserted below. */
typedef struct goss_landmarks {
    const float *points; /* point_count * 3 floats */
    uint32_t point_count;
    float confidence;
    int64_t timestamp_us;
} goss_landmarks;

/* One face tracking result. Landmarks are x, y in frame pixels with z in
 * the same scale, three floats per point; a zero landmark_count means the
 * frame held no face. blendshapes are 52 scores in zero to one. Layout:
 * 5968 bytes, static-asserted below. */
#define GOSS_FACE_LANDMARK_COUNT 478u
#define GOSS_FACE_BLENDSHAPE_COUNT 52u
#define GOSS_FACE_MAX 4u
typedef struct goss_face_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    float presence;
    uint32_t landmark_count;
    float landmarks[GOSS_FACE_LANDMARK_COUNT * 3];
    float blendshapes[GOSS_FACE_BLENDSHAPE_COUNT];
} goss_face_result;

/* Canned gesture classes, in the classifier's own label order. Zero is
 * the no-gesture class, also reported when no gesture model is loaded. */
#define GOSS_GESTURE_NONE 0u
#define GOSS_GESTURE_CLOSED_FIST 1u
#define GOSS_GESTURE_OPEN_PALM 2u
#define GOSS_GESTURE_POINTING_UP 3u
#define GOSS_GESTURE_THUMB_DOWN 4u
#define GOSS_GESTURE_THUMB_UP 5u
#define GOSS_GESTURE_VICTORY 6u
#define GOSS_GESTURE_ILOVEYOU 7u

/* One tracked hand. handedness is the model's score that this is a right
 * hand; gesture is a GOSS_GESTURE_* class with its score; landmarks are
 * x, y in frame pixels with z in the same scale, three floats per point. */
#define GOSS_HAND_LANDMARK_COUNT 21u
#define GOSS_HAND_MAX 2u
typedef struct goss_hand {
    float presence;
    float handedness;
    uint32_t gesture;
    float gesture_score;
    float landmarks[GOSS_HAND_LANDMARK_COUNT * 3];
} goss_hand;

/* One hand tracking result. A zero hand_count means the frame held no
 * hands; hands beyond hand_count are zeroed. Layout: 560 bytes,
 * static-asserted below. */
typedef struct goss_hand_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    uint32_t hand_count;
    uint32_t reserved;
    goss_hand hands[GOSS_HAND_MAX];
} goss_hand_result;

/* One pose tracking result: a 33-point skeleton in frame pixels with z
 * in the same scale, plus zero-to-one visibility and presence scores per
 * point. A zero landmark_count means the frame held no body. Layout:
 * 688 bytes including tail padding, static-asserted below. */
#define GOSS_POSE_LANDMARK_COUNT 33u
typedef struct goss_pose_result {
    uint64_t frame_serial;
    int64_t timestamp_us;
    float presence;
    uint32_t landmark_count;
    float landmarks[GOSS_POSE_LANDMARK_COUNT * 3];
    float visibilities[GOSS_POSE_LANDMARK_COUNT];
    float presences[GOSS_POSE_LANDMARK_COUNT];
} goss_pose_result;

/* The most bodies the multi-person submit path keeps in one frame. */
#define GOSS_BODY_MAX 4u

/* The live signals goss_session_tick_lens evaluates a lens's compiled
 * triggers against (a GLF `when` expression's signal reads). blendshapes
 * mirrors goss_face_result's own inline-array convention rather than a
 * pointer, so a caller already holding a face result can pass its
 * blendshapes straight through; has_face false means every face-driven
 * signal (present, and any blendshape) reads as false regardless of
 * what blendshapes holds. Layout: 232 bytes, static-asserted below. */
typedef struct goss_lens_signals {
    bool has_face;
    bool hands_present;
    bool tap;
    uint8_t reserved;
    double world_tracking_state;
    double audio_level;
    float blendshapes[GOSS_FACE_BLENDSHAPE_COUNT];
} goss_lens_signals;

/* Bounds for the engine's frame-path pools. Zero means the built-in
 * default. Layout: 8 bytes. */
typedef struct goss_engine_config {
    uint32_t texture_pool_capacity;
    uint32_t staging_pool_capacity;
} goss_engine_config;

/* Per-session pipeline configuration. frame_budget_us is the whole-pipeline
 * frame time the degradation policy holds the session to; zero means the
 * built-in default of 33333, a 30 fps budget. Layout: 8 bytes. */
typedef struct goss_session_config {
    uint32_t frame_budget_us;
    uint32_t reserved; /* zero */
} goss_session_config;

/* Graph thread. config may be null for defaults. */
goss_status goss_engine_create(const goss_engine_config *config, goss_engine **out_engine);
void goss_engine_destroy(goss_engine *engine);

/* Graph thread. Brings up the render backend on the given surface. */
goss_status goss_engine_init_renderer(goss_engine *engine, const goss_renderer_desc *desc);

/* Graph thread. Resizes the render surface. */
void goss_engine_resize(goss_engine *engine, uint32_t width, uint32_t height);

/* Graph thread. Draws the session's most recent frame to the surface and
 * presents. A null session presents the clear color. */
goss_status goss_engine_render_frame(goss_engine *engine, goss_session *session);

/* Graph thread. Requests a screenshot of the next presented frame,
 * written as path (path_len bytes, not necessarily nul-terminated) plus
 * a ".tga" suffix the renderer's own callback appends. Debug/test
 * tooling only - conformance harnesses, never a user-facing control. */
goss_status goss_engine_request_screenshot(goss_engine *engine, const uint8_t *path, size_t path_len);

/* Graph thread. Renders and presents like goss_engine_render_frame, and
 * also reads the composited output back into out_data as RGBA8 (row 0
 * first), reporting the real image size through out_width/out_height.
 * out_data must already be at least render_surface_width *
 * render_surface_height * 4 bytes (the same dimensions passed to
 * goss_engine_init_renderer, or the most recent goss_engine_resize) - the
 * call fails with invalid_argument rather than truncating silently if
 * out_capacity is smaller. Debug/test tooling only, for render backends
 * with no synchronous pixel-readback API of their own. On the WebGPU
 * backend this issues two internal frame submits (see
 * third_party/bgfx/patches/0003-webgpu-readtexture-wait-any.patch for
 * the wait-mode fix this also depends on) since bgfx's own read-texture
 * command only runs on the frame after the one that queues it. */
goss_status goss_engine_capture_frame(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height);

/* The supported per-frame composited output for a live broadcast source (a
 * LiveKit/WebRTC custom video source), read back in a WebRTC format so the
 * caller publishes it with no swizzle. format is GOSS_PIXEL_RGBA8, BGRA8, or
 * NV12 (BT.709 video range); out_data holds width*height*4 for the packed
 * formats or width*height*3/2 for NV12. The blessed live path, not debug. */
goss_status goss_engine_capture_live_frame(goss_engine *engine, goss_session *session, uint32_t format, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height);

/* The zero-copy live output: renders the composited frame straight into a
 * caller-supplied external texture (an id<MTLTexture> over an IOSurface-backed
 * CVPixelBuffer on Apple) instead of reading it back. Returns GOSS_AGAIN while a
 * new handle or size warms up bgfx's override; re-submit next frame. Metal today. */
goss_status goss_engine_render_to_live_texture(goss_engine *engine, goss_session *session, uint64_t native_handle, uint32_t width, uint32_t height);

/* Captures the composited frame and encodes it as a PNG into out_data.
 * out_len always receives the encoded size, so a too-small buffer
 * (invalid_argument) tells the caller exactly what to retry with. The
 * encoding is deterministic: the same pixels, the same bytes. */
goss_status goss_engine_capture_photo(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

/* Captures the composited frame as a platform photo (1 = JPEG,
 * 2 = HEIC) at quality percent; out_len always receives the needed
 * size. Lossy and not bit-stable across runs - capture_photo stays
 * the deterministic PNG surface. UNSUPPORTED without a backend. */
goss_status goss_engine_capture_photo_as(goss_engine *engine, goss_session *session, uint32_t format, uint32_t quality, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

typedef struct goss_recording_config {
  uint32_t width;       /* 0 picks the renderer's output size (rounded to even) */
  uint32_t height;
  uint32_t bitrate_bps; /* 0 lets the backend pick a rate for the size */
  uint32_t codec;       /* 0 = H.264, 1 = HEVC */
} goss_recording_config;

/* Starts recording the session's rendered frames, effects baked in,
 * into the file at path. One recording per engine; every subsequent
 * goss_engine_render_frame of this session appends one video frame at
 * the frame's own timestamp until goss_engine_recording_stop. Returns
 * GOSS_ERROR_UNSUPPORTED where no recording backend exists yet. */
goss_status goss_engine_recording_start(goss_engine *engine, goss_session *session, const uint8_t *path, size_t path_len, const goss_recording_config *config);

/* Stops the engine's recording, flushing frames still in flight and
 * finalizing the container. */
goss_status goss_engine_recording_stop(goss_engine *engine);

/* What interrupted a recording, as the host saw it. A declared break is a gap the
 * output accounts for, rather than drift the engine is blamed for. */
typedef enum goss_interruption {
    GOSS_INTERRUPTION_PAUSE = 0,
    GOSS_INTERRUPTION_CAMERA_LOST = 1,
    GOSS_INTERRUPTION_AUDIO_ROUTE = 2,
    GOSS_INTERRUPTION_BACKGROUNDED = 3,
    GOSS_INTERRUPTION_THERMAL = 4,
} goss_interruption;

typedef struct goss_recording_report {
    int64_t duration_us;    /* output length, with the paused spans removed */
    uint32_t clips;         /* pause and resume pairs produce these, from one */
    uint32_t interruptions; /* declared breaks of every kind */
    int64_t drift_us;       /* largest gap that was not a declared break */
    uint64_t frames;
    uint64_t dropped;
    uint32_t paused;
} goss_recording_report;

/* Graph thread. Holds the recording clock. Frames submitted while paused are not
 * written and the output has no gap, so a pause and resume pair is a clip
 * boundary rather than a hole the rest of the file drifts behind. */
goss_status goss_engine_recording_pause(goss_engine *engine);
goss_status goss_engine_recording_resume(goss_engine *engine);

/* Graph thread. A break the host saw rather than one the engine can detect. */
goss_status goss_session_report_interruption(goss_session *session, goss_interruption kind);

/* Any thread. What the recording has done so far. */
goss_status goss_engine_recording_read_report(goss_engine *engine, goss_recording_report *out_report);

/* Tells the next recording whether a viewfinder is watching it. True is the live camera and
 * the default; an offline lane rendering a clip faster than real time passes false, and the
 * composite then goes straight to the encoder rather than waiting on a display refresh.
 * Frames carry their own timestamps either way. */
goss_status goss_engine_recording_set_realtime(goss_engine *engine, bool realtime);

/* Feeds interleaved f32 PCM into the session: the engine's own level
 * and beat analysis always consumes it (driving the audio.level and
 * audio.beat trigger signals), and an active recording of this session
 * muxes it as the audio track where the backend supports audio. */
goss_status goss_session_submit_audio(goss_session *session, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels, int64_t timestamp_us);

typedef struct goss_world_state {
    uint32_t tracking_state; /* 0 unavailable, 1 initializing, 2 tracking, 3 limited */
    float world_from_camera[16]; /* column-major camera pose in world space */
    float projection[16];        /* the platform camera's real projection */
    int64_t timestamp_us;
} goss_world_state;

typedef struct goss_world_plane {
    uint64_t id;
    float pose[16];
    float extent_x;
    float extent_z;
    uint32_t classification; /* 0 other, 1 floor, 2 wall, 3 ceiling, 4 table */
} goss_world_plane;

typedef struct goss_world_anchor {
    uint64_t id;
    float pose[16];
} goss_world_anchor;

typedef struct goss_world_light {
    float ambient_intensity;
    float color_temperature_kelvin;
} goss_world_light;

/* Guided-capture progress returned by goss_session_capture_view. Layout: 24
 * bytes. */
/* What a lens node is doing, as against what its manifest asked for. */
typedef enum goss_node_state {
    GOSS_NODE_STATE_READY = 0,     /* the author got what they wrote */
    GOSS_NODE_STATE_DEGRADED = 1,  /* the node draws, without something it named */
    GOSS_NODE_STATE_FAILED = 2,    /* the node draws nothing */
} goss_node_state;

/* Why a node is not ready. A host can retry a missing asset and can only
 * apologise for an unsupported model, so the set is fixed and branchable. */
typedef enum goss_node_reason {
    GOSS_NODE_REASON_NONE = 0,
    GOSS_NODE_REASON_OUT_OF_MEMORY = 1,
    GOSS_NODE_REASON_ASSET_MISSING = 2,
    GOSS_NODE_REASON_ASSET_MALFORMED = 3,
    GOSS_NODE_REASON_ASSET_TOO_LARGE = 4,
    GOSS_NODE_REASON_SHADER_MISSING = 5,
    GOSS_NODE_REASON_SHADER_LINK_FAILED = 6,
    GOSS_NODE_REASON_MODEL_REJECTED = 7,
    GOSS_NODE_REASON_MODEL_UNSUPPORTED = 8,
    GOSS_NODE_REASON_CAPABILITY_UNAVAILABLE = 9,
    GOSS_NODE_REASON_CONSTRAINT_FAILED = 10, /* physics refused a body or joint */
} goss_node_reason;

/* What the engine is doing now, as against what it was asked for. Every field
 * is measured rather than configured, so a host metering an agent or chasing a
 * budget reads one struct instead of guessing. */
typedef struct goss_engine_report {
    uint32_t renderer_backend;         /* the backend bgfx brought up, bgfx's own numbering */
    uint32_t zero_copy_import;         /* 1 when the android ycbcr import came up */
    uint32_t texture_pool_capacity;
    uint32_t texture_pool_live;
    uint32_t texture_pool_peak;
    uint32_t texture_pool_exhausted;   /* requests that found nothing free */
    uint32_t staging_pool_capacity;
    uint32_t staging_pool_live;
    uint32_t staging_pool_peak;
    uint32_t staging_pool_exhausted;
    uint32_t texture_pool_bins;         /* distinct descriptions held; 0 means nothing pooled */
    uint32_t texture_pool_bins_refused; /* descriptions turned away at the bin cap */
    uint32_t staging_pool_bins;
    uint64_t bgfx_live_bytes;          /* held on the heap no managed allocator sees */
    uint64_t bgfx_alloc_calls_last_frame;
    uint64_t bgfx_bytes_last_frame;
} goss_engine_report;

/* Per-session counters: what this session was asked to do, and how much of it
 * it actually did. */
typedef struct goss_session_report {
    uint64_t frames_submitted;
    uint64_t frames_rendered;
    uint32_t degrade_level;       /* goss_degrade_level */
    uint32_t degrade_transitions; /* a number that keeps climbing is flapping */
    uint64_t face_analysis;
    uint64_t hand_analysis;
    uint64_t pose_analysis;
    uint64_t segmentation_analysis;
    uint64_t ml_analysis;
    uint32_t nodes_degraded;
    uint32_t node_reports_lost;
    uint32_t script_faults;       /* handlers and ticks that threw; a lens still draws */
} goss_session_report;

/* One node's diagnostic. node_index is the node's index in the session graph,
 * and the key goss_session_node_report_id resolves to a manifest id. */
typedef struct goss_node_report {
    uint32_t node_index;
    uint32_t state;  /* goss_node_state */
    uint32_t reason; /* goss_node_reason */
} goss_node_report;

typedef struct goss_capture_guidance {
    uint32_t covered;     /* target viewpoints covered so far */
    uint32_t total;       /* total target viewpoints in the scan */
    uint32_t complete;    /* 1 when every target is covered */
    uint32_t view_count;  /* views captured so far */
    uint32_t splat_count; /* gaussians reconstructed so far */
    float next_yaw;       /* yaw (radians) of the next uncovered target */
} goss_capture_guidance;

/* Feeds the platform's world understanding into the session: camera
 * pose and projection, tracked planes, anchors, and the light
 * estimate, once per platform frame. Drives the world.tracking_state
 * trigger signal and world-anchored lens content. */
goss_status goss_session_submit_world(goss_session *session, const goss_world_state *state, const goss_world_plane *planes, size_t plane_count, const goss_world_anchor *anchors, size_t anchor_count, const goss_world_light *light);

/* Submits the device's pre-scanned world mesh (ARKit/ARCore reconstruction, a
 * VPS scan) in world space: vertex_count xyz triples and index_count indices,
 * three per triangle. The engine copies it, and a ray meets it through
 * goss_session_raycast_world_mesh. An empty submission clears the stored mesh. */
goss_status goss_session_submit_world_mesh(goss_session *session, const float *vertices, size_t vertex_count, const uint32_t *indices, size_t index_count);

/* Decodes a PNG to tightly packed RGBA8. A caller holding an encoded image and no
 * decoder of its own is the ordinary case in a server or a tool, and the engine
 * already carries the decoder for its own assets. GOSS_AGAIN with the size in
 * out_len when the buffer is short, so a caller sizes once. */
goss_status goss_engine_decode_png(const uint8_t *bytes, size_t len, uint8_t *out_rgba, size_t capacity, uint32_t *out_width, uint32_t *out_height, size_t *out_len);

/* A walkable path across the submitted world mesh, from start to goal, written as
 * out_count xyz triples. GOSS_AGAIN when no mesh is submitted, when no route
 * exists, or with the count when the buffer was short: a caller can act on "not
 * here" and cannot act on an empty list it mistook for a straight line. */
goss_status goss_session_path_across_world(goss_session *session, const float *start, const float *goal, float *out_points, size_t capacity, size_t *out_count);

/* A footprint to place, in metres. Height is asked for even on a flat surface:
 * it decides whether a thing fits under a shelf. */
typedef struct goss_footprint {
    float width;
    float depth;
    float height;
} goss_footprint;

/* Where a footprint can go: which plane, where on it in world space, and how
 * much of that surface stays free afterwards, as a fraction. */
typedef struct goss_placement {
    uint64_t plane_id;
    float position[3];
    float free_fraction;
} goss_placement;

/* Something already on a plane, on that plane's own axes in metres from its
 * centre, so a placement query answers about the surface as it is now. */
typedef struct goss_occupant {
    uint64_t plane_id;
    float x;
    float z;
    float width;
    float depth;
} goss_occupant;

/* One landmark as it crosses between two devices. No pose: a pose is meaningless
 * in another origin. The position is in the sender's own frame, read only for the
 * distances between landmarks. */
typedef struct goss_shared_landmark {
    uint64_t id;
    float x;
    float y;
    float z;
    float confidence;
} goss_shared_landmark;

/* What a submitted plane is, as a named kind rather than the platform's own
 * number: 0 unknown, 1 floor, 2 wall, 3 ceiling, 4 table, 5 seat, 6 door,
 * 7 window, 8 screen. out_bearing is 1 when a thing can rest on it. */
goss_status goss_session_plane_kind(goss_session *session, uint64_t plane_id, uint32_t *out_kind, uint32_t *out_bearing);

/* The plane this session would call the floor: the lowest bearing surface it has
 * been shown. GOSS_AGAIN when it has been shown none. */
goss_status goss_session_floor_plane(goss_session *session, uint64_t *out_plane_id);

/* Where this footprint fits, best surface first: the bearing plane with the most
 * room left afterwards. out_count is the number found; GOSS_AGAIN with the count
 * when the buffer was short. Zero placements is an answer. */
goss_status goss_session_place_on(goss_session *session, const goss_footprint *item, const goss_occupant *occupants, size_t occupant_count, goss_placement *out, size_t capacity, size_t *out_count);

/* Point to point in metres, with the uncertainty that follows from the accuracy
 * each end carried. Pass a non-positive accuracy to vouch for none; out_known is
 * then 0, so a sigma of zero is never read as certainty. */
goss_status goss_session_measure_between(goss_session *session, const float *from, float from_accuracy_m, const float *to, float to_accuracy_m, float *out_metres, float *out_sigma, uint32_t *out_known);

/* What this device can offer another: one landmark per world anchor it holds, in
 * its own frame. GOSS_AGAIN with the count when the buffer was short. */
goss_status goss_session_shared_landmarks(goss_session *session, goss_shared_landmark *out, size_t capacity, size_t *out_count);

/* The transform from the sender's origin into this one, column-major, solved over
 * the landmarks both sides recognise, with the fit it achieved. GOSS_AGAIN when
 * fewer than three matched, which cannot fix a rigid transform. */
goss_status goss_session_align_shared(goss_session *session, const goss_shared_landmark *theirs, size_t count, float *out_transform, float *out_rms_error, uint32_t *out_matched);

/* Casts a world-space ray (origin and direction) against the submitted world
 * mesh and writes the nearest surface hit into out_point with its ray distance
 * into out_distance. GOSS_AGAIN when no mesh is submitted or the ray misses, so
 * a tap-to-place lens anchors content where the ray meets the scanned geometry. */
goss_status goss_session_raycast_world_mesh(goss_session *session, const float *origin, const float *direction, float *out_point, float *out_distance);

/* Raycasts a normalized screen point (0..1, origin top-left) against the
 * tracked ground plane and writes the world hit position into out_position
 * (three floats). Returns goss_again until world tracking is in its tracked
 * state and the ray meets the plane, so a tap-to-place lens polls it and
 * places an anchor at the hit. */
goss_status goss_session_hit_test(goss_session *session, float screen_x, float screen_y, float *out_position);

typedef struct goss_capture_config {
  uint32_t width;       /* 0 = the submitted frame's own resolution */
  uint32_t height;
  uint32_t supersample; /* 0 or 1 = 1:1, 2 or 4 = render larger then downsample */
  uint32_t format;      /* 0 = PNG, 1 = JPEG, 2 = HEIC */
  uint32_t quality;     /* 1..100 for lossy formats, 0 = backend default */
  uint32_t color_space; /* 0 = sRGB, 1 = Display-P3, 2 = Rec2020 */
  uint32_t bit_depth;   /* 8 or 16; 16 is the PNG high-bit-depth path */
} goss_capture_config;

/* Composites the still at the configured resolution - the submitted
 * frame's own size when width and height are zero - independent of the
 * preview swap chain, and encodes it. out_len always receives the
 * encoded size. PNG has no size ceiling and carries the color-space
 * tag; JPEG is the engine's own encoder on every target; HEIC needs the
 * platform photo backend. */
goss_status goss_engine_capture_still(goss_engine *engine, goss_session *session, const goss_capture_config *config, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height);

/* Declarative camera-hardware intent. The engine validates and normalizes
 * every field and stores it on the session; the SDK reads the normalized
 * values back and drives the platform camera. The core never touches camera
 * hardware. Layout: 56 bytes, static-asserted below. */
typedef struct goss_camera_controls {
  uint32_t flash_mode;         /* 0 off, 1 on, 2 auto (still-capture LED) */
  uint32_t torch;              /* 0 off, 1 on (continuous LED) */
  uint32_t focus_mode;         /* 0 continuous-auto, 1 locked, 2 point-single */
  uint32_t exposure_mode;      /* 0 continuous-auto, 1 locked */
  float    focus_point_x;      /* tap POI, normalized 0..1 (clamped) */
  float    focus_point_y;
  uint32_t exposure_linked;    /* 1 exposure POI follows focus POI, 0 decoupled */
  float    exposure_point_x;   /* used when decoupled, 0..1 (clamped) */
  float    exposure_point_y;
  float    exposure_bias_ev;   /* clamped to [-8, 8]; SDK re-clamps to device */
  float    zoom_factor;        /* >= 1; clamped to [1, max_zoom_factor or 128] */
  float    max_zoom_factor;    /* SDK-reported device ceiling; 0 = unknown */
  uint32_t mirror_save_policy; /* 0 uniform (front mirrors every surface) */
  uint32_t reserved;           /* zero */
} goss_camera_controls;

/* Graph thread. Validates and normalizes controls into the session; the SDK
 * reads them back with goss_session_camera_controls and applies them to the
 * platform camera. */
goss_status goss_session_set_camera_controls(goss_session *session, const goss_camera_controls *controls);
goss_status goss_session_camera_controls(goss_session *session, goss_camera_controls *out);

/* How the SDK should record. The engine only stores this intent; it never drives
 * the recorder. Layout: 40 bytes, static-asserted below. */
typedef struct goss_recording_policy {
    uint32_t max_duration_ms; /* 0 unlimited, else a hard clip cap */
    uint32_t min_clip_ms;     /* a segment shorter than this is dropped */
    uint32_t segment_mode;    /* 0 single take, 1 multi-clip pause/resume */
    uint32_t loop_playback;   /* 0 off, 1 loop the recorded clip */
    uint32_t speed_preset;    /* 0 1x, 1 0.3x, 2 0.5x, 3 2x, 4 3x */
    uint32_t mic_muted;       /* 0 record mic, 1 mute */
    uint32_t save_original;   /* 0 off, 1 keep the unprocessed take too */
    uint32_t stabilization;   /* 0 off, 1 standard, 2 cinematic */
    uint32_t reserved0;
    uint32_t reserved1;
} goss_recording_policy;

/* The capture chrome the app draws over its own surface. The engine only stores
 * the intent; the front-screen flash is a brightness/warmth fill the app draws,
 * not baked into the captured frame. Layout: 40 bytes, static-asserted below. */
typedef struct goss_capture_ui {
    uint32_t grid_mode;              /* 0 off, 1 thirds, 2 golden, 3 square */
    uint32_t level_indicator;        /* 0 off, 1 on */
    uint32_t shutter_mode;           /* 0 photo, 1 hold-video, 2 handsfree, 3 loop, 4 timer */
    uint32_t countdown_s;            /* self-timer seconds, 0 off */
    uint32_t night_mode;             /* 0 off, 1 on, 2 auto */
    uint32_t screen_flash_mode;      /* 0 off, 1 on, 2 auto (front-screen fill) */
    float screen_flash_intensity;    /* 0..1 brightness of the fill */
    float screen_flash_warmth;       /* 0 cool .. 1 warm */
    uint32_t reserved0;
    uint32_t reserved1;
} goss_capture_ui;

/* Graph thread. The engine validates and stores these; the SDK reads them back
 * and applies them to the platform recorder and the capture UI. */
goss_status goss_session_set_recording_policy(goss_session *session, const goss_recording_policy *policy);
goss_status goss_session_recording_policy(goss_session *session, goss_recording_policy *out);
goss_status goss_session_set_capture_ui(goss_session *session, const goss_capture_ui *ui);
goss_status goss_session_capture_ui(goss_session *session, goss_capture_ui *out);

/* Graph thread. config may be null for defaults. */
goss_status goss_session_create(goss_engine *engine, const goss_session_config *config, goss_session **out_session);
void goss_session_destroy(goss_session *session);

/* Graph thread. Hands over one camera frame, zero-copy. The descriptor is
 * copied; the plane handles are wrapped, not read, and their platform
 * objects must outlive the next rendered frame. */
goss_status goss_session_submit_frame(goss_session *session, const goss_frame_desc *desc, const goss_frame_planes *planes);

/* Any-thread, pure. Writes the YCbCr to RGB conversion for a standard and
 * range as one column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).
 * out_matrix holds 16 floats. */
goss_status goss_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix);

/* Any-thread, pure. Analytic two-bone inverse kinematics for a limb: root, the
 * upper and lower bone lengths, the target the end effector reaches for, and
 * the pole the joint bends toward. Writes the mid joint and end positions
 * (three floats each). An unreachable target extends the limb straight at it. */
goss_status goss_solve_two_bone_ik(const float *root, float upper_len, float lower_len, const float *target, const float *pole, float *out_mid, float *out_end);

/* Graph thread. The stated CPU path: copies NV12 planes into pooled
 * textures for SDKs whose zero-copy import is not wired yet. The copy is
 * counted; prefer goss_session_submit_frame. */
goss_status goss_session_submit_frame_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Zero-copy submission of a platform hardware buffer
 * (AHardwareBuffer). Any status other than GOSS_OK means this stream falls
 * back to goss_session_submit_frame_copy. */
goss_status goss_session_submit_hardware_buffer(goss_session *session, const goss_frame_desc *desc, void *hardware_buffer);

/* Graph thread. Reports one finished frame: measured whole-pipeline time
 * plus current thermal pressure. Returns the degradation level in effect
 * for the next frame. This is the only input that walks the ladder, and the
 * level changes what the engine does rather than only what it reports: each
 * rung lengthens the analysis strides, and the bottom rung stops the lens and
 * beauty chains. Capture and recording keep full frame rate at every rung. */
goss_degrade_level goss_session_report_frame(goss_session *session, uint32_t frame_time_us, goss_thermal thermal);

/* Graph thread. The level currently in effect. */
goss_degrade_level goss_session_degrade_level(const goss_session *session);

/* Graph thread. Stands the face tracking worker up from a model bundle
 * (a MediaPipe .task file). The bundle bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
goss_status goss_session_enable_face_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_face_tracking(goss_session *session);

/* Graph thread. Stands the hand tracking worker up from a model bundle:
 * a hand landmarker .task, or a gesture recognizer .task whose nested
 * gesture models additionally score each hand's canned gesture. The
 * bundle bytes are copied; the caller may release them on return.
 * Builds without the inference stack report unsupported. */
goss_status goss_session_enable_hand_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_hand_tracking(goss_session *session);

/* Graph thread. Stands the pose tracking worker up from a model bundle
 * (a MediaPipe pose landmarker .task file). The bundle bytes are copied;
 * the caller may release them on return. Builds without the inference
 * stack report unsupported. */
goss_status goss_session_enable_pose_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads);
void goss_session_disable_pose_tracking(goss_session *session);

/* Graph thread. Upper-body pose mode: while enabled (non-zero), the tracked
 * pose reports only the upper body (face, torso, arms, hips); the lower-body
 * joints (knees, ankles, feet) read absent, for selfie framing with legs out. */
goss_status goss_session_set_pose_upper_body(goss_session *session, uint32_t enabled);

/* Graph thread. Stands the segmentation worker up from a raw model
 * (a selfie or hair segmenter .tflite file, not bundled the way
 * face_landmarker.task is). The model bytes are copied; the caller may
 * release them on return. Builds without the inference stack report
 * unsupported. */
goss_status goss_session_enable_segmentation(goss_session *session, const uint8_t *model_bytes, size_t model_len, int32_t threads);
/* Graph thread. Allowlists a bring-your-own model by its 32-byte SHA-256
 * digest, so a net whose digest is not listed is refused when a tracker or
 * segmenter is enabled; re-adding a digest is a no-op. clear_model_allowlist
 * empties it. With none set, any model loads (the default). Call before
 * enabling the worker. */
goss_status goss_session_allow_model_digest(goss_session *session, const uint8_t *digest);
goss_status goss_session_clear_model_allowlist(goss_session *session);

/* Graph thread. Hands the engine one bundle asset's bytes under its
 * manifest name ahead of a JSON lens activation, so a filesystem-less host
 * (the web) runs the heavy inference nodes from memory. The name must stay
 * bundle-relative; zero-length bytes remove a previously staged name. Names
 * every node type reads through, images included, so a host that fetches a
 * lens over the network runs the same lens a directory install runs. */
goss_status goss_session_provide_lens_asset(goss_session *session, const uint8_t *name, size_t name_len, const uint8_t *bytes, size_t len);

/* Graph thread. Reads one placed node's live rect (normalized, origin
 * top-left) and its turn in degrees clockwise: the authored angle, replaced
 * by any bound parameter, plus any gesture the wearer applied. For a host
 * drawing selection handles or persisting where a sticker was left. Any out
 * pointer may be NULL. */
goss_status goss_session_sprite_transform(goss_session *session, const uint8_t *node_id, size_t node_id_len, float *out_x, float *out_y, float *out_w, float *out_h, float *out_rotation);

/* Graph thread. Copies one ml.infer node's whole published output tensor
 * into caller memory, the element count written to out_len. capacity is in
 * floats; a short buffer reports the needed count and answers GOSS_AGAIN, the
 * same sizing answer every other op here gives, so a detection, embedding or
 * logits read sizes itself in two calls. GOSS_AGAIN before the first publish. */
goss_status goss_session_ml_output(goss_session *session, const uint8_t *node_id, size_t node_id_len, uint32_t tensor, float *out, size_t capacity, size_t *out_len);

/* Graph thread. Copies one ml.infer node's mask-bound output into caller
 * memory, freshly read and resampled to the fixed segmentation plane the
 * compositor samples; out_len reports that plane's float count.
 * GOSS_INVALID_ARGUMENT when the node has no mask binding. */
goss_status goss_session_ml_mask(goss_session *session, const uint8_t *node_id, size_t node_id_len, float *out, size_t capacity, size_t *out_len);
void goss_session_disable_segmentation(goss_session *session);

/* Graph thread. Feeds one NV12 frame to the tracking worker. The planes
 * are CPU addresses valid for the duration of the call; the worker copies
 * and returns immediately, dropping stale frames in favor of this one.
 * Feeds the segmentation worker the same frame if it is enabled too. */
goss_status goss_session_track_frame(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. Runs each selfie-source splat.cloud once over a submitted
 * still (NV12, the layout track_frame takes), so a photoreal avatar is
 * generated from one photo and then held. The worker publishes off the frame
 * thread; a later render draws its points. GOSS_AGAIN with no selfie avatar. */
goss_status goss_session_submit_avatar_source(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);

/* Graph thread. The web selfie path: converts one host RGBA still to NV12 and
 * runs each selfie-source splat.cloud once over it, the RGBA sibling of
 * goss_session_submit_avatar_source. GOSS_AGAIN with no selfie avatar. */
goss_status goss_session_submit_avatar_source_rgba(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread. Reads the newest tracking result into caller memory.
 * Reports GOSS_AGAIN until the worker has published its first result. */
goss_status goss_session_face_result(goss_session *session, goss_face_result *out_result);

/* Graph thread. Submits the faces tracked this frame for the multi-face
 * path. count past GOSS_FACE_MAX is clamped; zero clears the path back to
 * the single tracker. Faces below the tracked presence or with no
 * landmarks drop, so the count only holds real faces. */
goss_status goss_session_submit_faces(goss_session *session, const goss_face_result *faces, uint32_t count);

/* Graph thread. Writes how many faces the last goss_session_submit_faces
 * kept, zero to GOSS_FACE_MAX. Zero also means no multi-face path this
 * frame. */
goss_status goss_session_face_count(goss_session *session, uint32_t *out_count);

/* Graph thread. Reads the index-th submitted face. Returns
 * GOSS_ERROR_INVALID_ARGUMENT once index reaches the face count, so a
 * caller loops zero to the count to visit every face. */
goss_status goss_session_face_result_at(goss_session *session, uint32_t index, goss_face_result *out_result);

/* Graph thread. Reads the stable track id of the index-th face, an integer
 * that stays with the same person across frames as the submission order
 * shuffles, refreshed each tick. GOSS_ERROR_INVALID_ARGUMENT once index
 * reaches the face count. */
goss_status goss_session_face_track_id(goss_session *session, uint32_t index, uint32_t *out_id);

/* Graph thread. Submits the bodies tracked this frame for the multi-person
 * path. count past GOSS_BODY_MAX is clamped; zero clears the path. Bodies
 * below the tracked presence or with no landmarks drop. */
goss_status goss_session_submit_bodies(goss_session *session, const goss_pose_result *bodies, uint32_t count);

/* Graph thread. Submits the hands tracked this frame from the host's own
 * tracker, so hand signals, gestures, and joints work with no built-in
 * worker; host-submitted hands win over the worker while set. Hands past
 * GOSS_HAND_MAX or below the presence threshold drop; NULL clears the path
 * back to the built-in worker. */
goss_status goss_session_submit_hands(goss_session *session, const goss_hand_result *hands);

/* Graph thread. Writes how many bodies the last goss_session_submit_bodies
 * kept, zero to GOSS_BODY_MAX. */
goss_status goss_session_body_count(goss_session *session, uint32_t *out_count);

/* Graph thread. Reads the index-th submitted body. Returns
 * GOSS_ERROR_INVALID_ARGUMENT once index reaches the body count, so a caller
 * loops zero to the count to visit every body. */
goss_status goss_session_body_result_at(goss_session *session, uint32_t index, goss_pose_result *out_result);

/* Graph thread. Submits one frame's depth map from the host AR backend
 * (ARKit scene depth, ARCore Depth API, WebXR depth-sensing): width*height
 * metres per pixel, row major, with the near and far metres that bound it.
 * A zero size clears it. Kept for depth occlusion against the content. */
goss_status goss_session_submit_depth(goss_session *session, const float *depth, uint32_t width, uint32_t height, float near, float far);

/* Graph thread. Submits the camera intrinsics an undistort.pass corrects for:
 * the focal lengths and principal point in pixels of the submitted frame, and
 * the radial distortion coefficients (k1, k2 read; further terms ignored). A
 * zero focal length or zero coefficient count clears them. */
goss_status goss_session_submit_camera_intrinsics(goss_session *session, float fx, float fy, float cx, float cy, const float *distortion, uint32_t distortion_len);

/* Feeds one device gravity sample (an orientation vector, any scale) with its
 * timestamp in microseconds. A rolling.pass reads the image-plane angular
 * velocity derived from consecutive samples to correct rolling-shutter skew; the
 * host submits one per frame from the IMU. A near-zero vector clears the stream. */
goss_status goss_session_submit_orientation(goss_session *session, float gravity_x, float gravity_y, float gravity_z, int64_t timestamp_us);

/* Feeds a host info value keyed by name, the rail an info sticker reads: a
 * text.2d node with a matching content_source shows the latest value each frame
 * (a time, a place, a sensor reading). A null or empty value clears the key.
 * Keys and values are copied, so the caller keeps ownership of its buffers. */
goss_status goss_session_set_info(goss_session *session, const uint8_t *key, size_t key_len, const uint8_t *value, size_t value_len);

/* Serializes the active lens's parameter state into out_buf (a count then the
 * values) with the byte length in out_len; GOSS_AGAIN with no lens. A connected
 * lens publishes this blob for the cloud to sync to peers; the deterministic tick
 * plus the applied state is the shared state. A NULL out_buf reports the size. */
goss_status goss_session_snapshot_lens_state(goss_session *session, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Applies a peer's lens-state blob to the active lens: each value is clamped into
 * its parameter so two runtimes on the same lens converge. GOSS_AGAIN with no
 * lens. A short or over-long blob applies only the parameters it covers. */
goss_status goss_session_apply_lens_state(goss_session *session, const uint8_t *blob, size_t blob_len);

/* Writes a content-provenance manifest for the active lens into out_buf as JSON:
 * the producer, the lens id, whether the frame is model-generated (a diffusion node)
 * or edited (any lens node), and the operations that touched it. The host binds
 * this to a capture per C2PA. GOSS_AGAIN with no lens; a NULL out_buf sizes it. */
goss_status goss_session_capture_provenance(goss_session *session, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Captures the current viewpoint (the last submitted world pose and depth) into a
 * guided scan: marks the yaw target it covers, back-projects the depth into
 * world-space gaussians, and fills out_guidance with the scan's coverage. The
 * reconstruction is deterministic. goss_session_reset_capture clears the scan. */
goss_status goss_session_capture_view(goss_session *session, goss_capture_guidance *out_guidance);
goss_status goss_session_reset_capture(goss_session *session);

/* Any thread. What the last drawn frame did with the active lens: the stages
 * ready to draw, the stages it has, and whether the beauty bridge ran. Zero
 * ready over a non-zero total is a lens the engine activated and is drawing
 * nothing of, which is what a host shows instead of an unchanged picture. */
goss_status goss_session_chain_report(goss_session *session, uint32_t *out_ready, uint32_t *out_total, uint32_t *out_beauty);

/* Graph thread. Copies the scan's reconstruction out as gaussians, fourteen
 * floats each: xyz, scale, a rotation quaternion, opacity and rgb. A NULL out
 * sizes it, so a caller asks for the count and then for the floats. This is what
 * a client writes into a moment file. */
goss_status goss_session_read_reconstruction(goss_session *session, float *out, uint32_t capacity, uint32_t *out_count);

/* Graph thread. Puts a reconstruction back, replacing whatever the scan held, so
 * a moment captured on one client opens on another. count is gaussians, not
 * floats. */
goss_status goss_session_write_reconstruction(goss_session *session, const float *gaussians, uint32_t count);

/* Graph thread. A named source's frame as a platform hardware buffer, the
 * zero-copy ingress the camera already had: without it a second camera or a
 * screen reaches the compositor only through a full RGBA copy. NV12 only; any
 * status but GOSS_OK means fall back to submit_source_frame_rgba_copy. */
goss_status goss_session_submit_source_hardware_buffer(goss_session *session, const uint8_t *name, size_t name_len, const goss_frame_desc *desc, void *hardware_buffer);

/* Graph thread. What the engine is doing now: the backend it actually brought
 * up, the bounded pools with their peaks and exhaustion counts, and the heap
 * traffic of the frame just drawn. */
/* Names the operators a model needs and this build does not implement, one per
   line. GOSS_AGAIN with out_len set means the buffer was too short. */
goss_status goss_ml_op_support(const uint8_t *model, size_t model_len, uint8_t *out, size_t capacity, size_t *out_len);

/* One thing the frame says: where it is, how sure the engine is, what found it,
   and which line and paragraph it belongs to. The string comes through
   goss_session_text_string, so a caller sizes once. */
typedef struct goss_text_entry {
    float quad[8];
    float confidence;
    uint32_t origin;
    uint32_t script;
    uint32_t direction;
    uint32_t track_id;
    uint32_t line;
    uint32_t paragraph;
    uint32_t text_len;
    int64_t first_seen_us;
    int64_t last_seen_us;
} goss_text_entry;

/* Turns on the text rail with a caller-supplied detector, and a recogniser and
   dictionary where the caller has them. A detector alone finds where the text
   is; the recogniser is what turns it into a string. */
goss_status goss_session_enable_text(goss_session *session, const uint8_t *detector, size_t detector_len, const uint8_t *recognizer, size_t recognizer_len, const uint8_t *dictionary, size_t dictionary_len, uint32_t detect_side);
goss_status goss_session_disable_text(goss_session *session);
goss_status goss_session_text_count(goss_session *session, uint32_t *out_count, uint64_t *out_refused);
goss_status goss_session_text_at(goss_session *session, uint32_t index, goss_text_entry *out_entry);
/* GOSS_AGAIN with out_len set means the buffer was too short. */
goss_status goss_session_text_string(goss_session *session, uint32_t index, uint8_t *out, size_t capacity, size_t *out_len);

/* The memory plane. Nothing is remembered until a host opens it, and the bound
   is the host's, so the memory it was promised is the memory it gets. */
goss_status goss_session_memory_open(goss_session *session, uint32_t dim, uint32_t max_entries);
goss_status goss_session_memory_close(goss_session *session);
/* The same id replaces rather than duplicating. */
goss_status goss_session_memory_remember(goss_session *session, uint64_t id, const float *embedding, uint32_t dim);
goss_status goss_session_memory_forget(goss_session *session, uint64_t id);
goss_status goss_session_memory_search(goss_session *session, const float *query, uint32_t dim, uint32_t k, uint64_t *out_ids, float *out_scores, uint32_t *out_count);
goss_status goss_session_memory_stats(goss_session *session, uint32_t *out_count, uint64_t *out_bytes);
/* GOSS_AGAIN with out_len set means the buffer was too short. */
goss_status goss_session_memory_save(goss_session *session, uint8_t *out, size_t capacity, size_t *out_len);
goss_status goss_session_memory_load(goss_session *session, const uint8_t *bytes, size_t len);

/* The verbs a scope carries, one bit each. Reading is covered by the snapshot
 * sections; these are the things that change something or reach a resource.
 * Appended to, never reordered, so a stored mask keeps its meaning. */
typedef enum goss_verb {
    GOSS_VERB_ANNOTATE = 0,         /* draw back into the frame */
    GOSS_VERB_EGRESS = 1,           /* a frame out of the engine */
    GOSS_VERB_RECORD = 2,
    GOSS_VERB_REMEMBER = 3,         /* write the memory plane */
    GOSS_VERB_SEARCH_MEMORY = 4,
    GOSS_VERB_OPEN_CLIP = 5,
    GOSS_VERB_CAPTURE_SCREEN = 6,
    GOSS_VERB_SUBMIT_FRAME = 7,     /* feed pixels in */
    GOSS_VERB_SUBMIT_WORLD = 8,     /* planes, anchors, mesh, depth, pose, location */
    GOSS_VERB_SUBMIT_AUDIO = 9,
    GOSS_VERB_AUDIO_OUT = 10,       /* mixed audio out, the ear's egress */
    GOSS_VERB_SEAL_MEMORY = 11,     /* the index as bytes that outlive the process */
    GOSS_VERB_ACTIVATE_LENS = 12,   /* run author content */
    GOSS_VERB_LOAD_MODEL = 13,      /* arbitrary compute over the frame */
    GOSS_VERB_ENABLE_TRACKING = 14,
    GOSS_VERB_RETOUCH = 15          /* change how the person looks */
} goss_verb;

/* Reading a code or a fingerprint is deliberately not a verb: every scan op is a
 * pure function over pixels or samples the caller already holds, so a permission
 * there would gate nothing. */

/* Narrows what this session will answer. Sections are the snapshot bits, verbs
   the goss_verb bits. A session opens fully permissive and this only ever
   narrows: anything running inside the session can call it, so a scope that
   could widen itself would be advisory. Widening means a new session. A read out
   of scope is dropped from the record rather than failing the call; a verb out of
   scope returns GOSS_OUT_OF_SCOPE, which a host can grant, as against
   GOSS_UNSUPPORTED, which it cannot. */
goss_status goss_session_set_scope(goss_session *session, uint32_t sections, uint32_t verbs);
goss_status goss_session_scope(goss_session *session, uint32_t *out_sections, uint32_t *out_verbs);

/* The name of one verb, for a refusal an agent can act on and a permission prompt
 * a person can read. GOSS_AGAIN with the size when the buffer is short. */
goss_status goss_scope_verb_name(uint32_t verb, uint8_t *out, size_t capacity, size_t *out_len);
uint32_t goss_scope_verb_count(void);

/* One thing that can be captured. The scale factor is the field a caller must not
   ignore: a point sent back without it lands at half its intended place on a
   retina display. */
typedef struct goss_screen_surface {
    uint64_t id;
    uint32_t kind;
    float logical_width;
    float logical_height;
    float origin_x;
    float origin_y;
    float scale;
    uint32_t title_len;
} goss_screen_surface;

/* Zero surfaces is the honest answer for a host that has not been granted
   permission, so a caller prompts rather than reading an error. */
goss_status goss_engine_screen_count(goss_engine *engine, uint32_t *out_count);
goss_status goss_engine_screen_at(goss_engine *engine, uint32_t index, goss_screen_surface *out_surface);
goss_status goss_engine_screen_title(goss_engine *engine, uint32_t index, uint8_t *out, size_t capacity, size_t *out_len);
/* A scale of zero takes the surface's own. */
goss_status goss_session_open_screen(goss_session *session, uint64_t surface_id, float scale, uint32_t *out_screen);
goss_status goss_session_close_screen(goss_session *session, uint32_t screen);
/* GOSS_AGAIN means the screen has not changed since the last step. */
goss_status goss_session_step_screen(goss_session *session, uint32_t screen, const uint8_t *name, size_t name_len);
goss_status goss_session_screen_point(goss_session *session, uint32_t screen, float x, float y, float *out_logical, float *out_pixel, float *out_desktop);

/* The memory sealed under a host key: an index of embeddings is a record of what a
   camera saw, so a file lifted off the device should be bytes rather than a diary.
   The nonce is the caller's, because a nonce reused under one key breaks the
   cipher. GOSS_AGAIN with out_len set means the buffer was too short. */
goss_status goss_session_memory_save_sealed(goss_session *session, const uint8_t *key, const uint8_t *nonce, uint8_t *out, size_t capacity, size_t *out_len);
goss_status goss_session_memory_load_sealed(goss_session *session, const uint8_t *key, const uint8_t *bytes, size_t len);

/* Every snapshot section this build writes. A hand-written mask goes stale the
   moment a section is added, so ask rather than assume. */
uint32_t goss_perception_select_all(void);

goss_status goss_engine_read_report(goss_engine *engine, goss_engine_report *out_report);

/* Graph thread. This session's counters: frames in and out, the rung and how
 * often it moved, the analysis each modality actually ran, and the lens nodes
 * that are not ready. */
goss_status goss_session_read_report(goss_session *session, goss_session_report *out_report);

/* Graph thread. How many nodes of the active lens are not doing what the
 * manifest asked, and how many diagnostics could not be recorded at all. A zero
 * count beside a non-zero lost count means the lens degraded in ways the session
 * could not write down, which is not the same as a lens that is fine. Either out
 * pointer may be null. */
goss_status goss_session_node_report_count(goss_session *session, uint32_t *out_count, uint32_t *out_lost);

/* Graph thread. One node's diagnostic by position in the report list (not by
 * node index). GOSS_INVALID_ARGUMENT past the end. */
goss_status goss_session_node_report_at(goss_session *session, uint32_t index, goss_node_report *out_report);

/* Graph thread. The manifest id of the node a report names, so a host can say
 * which node rather than which index. A null out reports the length to size for;
 * GOSS_AGAIN when the active lens no longer carries that node. */
goss_status goss_session_node_report_id(goss_session *session, uint32_t index, uint8_t *out, size_t capacity, size_t *out_len);

/* Submits one exposure of an HDR bracket, fed only to bracket-source
 * temporal.fuse nodes (the live camera feeds the rest); the fusion publishes
 * once the ring holds a full bracket. The NV12 form takes the same planes as
 * submit_frame_copy, the RGBA form width*height*4 bytes row-major. Returns
 * goss_status_again when no bracket-source temporal.fuse node is active. */
goss_status goss_session_submit_frame_bracket(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride);
goss_status goss_session_submit_frame_bracket_rgba(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Segments a host-provided still RGBA image (width*height*4 bytes, row-major):
 * converts it to NV12 and feeds the running segmenter, so the next render
 * picks up the mask the way a camera frame would. Returns goss_status_again
 * when no segmenter is enabled on the session. */
goss_status goss_session_submit_segmentation_image(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Samples a reference photo's makeup color per face part and stores it, so a
 * tint.pass with "source": "reference" paints the live face in that photo's
 * color. rgba is width*height*4 row-major; landmarks is the reference face's
 * 478 x,y,z points in reference-pixel space. A zero landmark_count clears it. */
goss_status goss_session_set_makeup_reference(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height, const float *landmarks, uint32_t landmark_count);

/* Graph thread. Reads the newest hand tracking result into caller
 * memory. Reports GOSS_AGAIN until the worker has published its first
 * result. */
goss_status goss_session_hand_result(goss_session *session, goss_hand_result *out_result);

/* Named attach points on a tracked hand for goss_session_hand_joint. */
#define GOSS_HAND_JOINT_WRIST 0u
#define GOSS_HAND_JOINT_THUMB_TIP 1u
#define GOSS_HAND_JOINT_INDEX_TIP 2u
#define GOSS_HAND_JOINT_MIDDLE_TIP 3u
#define GOSS_HAND_JOINT_RING_TIP 4u
#define GOSS_HAND_JOINT_PINKY_TIP 5u
#define GOSS_HAND_JOINT_PALM 6u

/* Graph thread. Writes the hand_index-th tracked hand's named joint point
 * (x, y in frame pixels, z in the same scale) into out_xyz, so a lens pins
 * content to a fingertip or the wrist. GOSS_ERROR_INVALID_ARGUMENT on an
 * unknown joint or a hand index past the tracked count; GOSS_AGAIN with no
 * hand or a faint one. */
goss_status goss_session_hand_joint(goss_session *session, uint32_t hand_index, uint32_t joint, float *out_xyz);

/* Graph thread. Reads the newest pose tracking result into caller
 * memory. Reports GOSS_AGAIN until the worker has published its first
 * result. */
goss_status goss_session_pose_result(goss_session *session, goss_pose_result *out_result);

/* Named attach points on the tracked body skeleton for
 * goss_session_body_joint; left/right are the subject's own. */
#define GOSS_BODY_JOINT_HEAD 0u
#define GOSS_BODY_JOINT_LEFT_SHOULDER 1u
#define GOSS_BODY_JOINT_RIGHT_SHOULDER 2u
#define GOSS_BODY_JOINT_LEFT_ELBOW 3u
#define GOSS_BODY_JOINT_RIGHT_ELBOW 4u
#define GOSS_BODY_JOINT_LEFT_WRIST 5u
#define GOSS_BODY_JOINT_RIGHT_WRIST 6u
#define GOSS_BODY_JOINT_LEFT_HIP 7u
#define GOSS_BODY_JOINT_RIGHT_HIP 8u
#define GOSS_BODY_JOINT_LEFT_KNEE 9u
#define GOSS_BODY_JOINT_RIGHT_KNEE 10u
#define GOSS_BODY_JOINT_LEFT_ANKLE 11u
#define GOSS_BODY_JOINT_RIGHT_ANKLE 12u

/* Graph thread. Writes the tracked body's named skeleton joint point (x, y in
 * frame pixels, z in the same scale) into out_xyz, so a lens pins content to a
 * shoulder, a wrist, or a knee. GOSS_ERROR_INVALID_ARGUMENT on an unknown
 * joint; GOSS_AGAIN with no body or presence below threshold. */
goss_status goss_session_body_joint(goss_session *session, uint32_t joint, float *out_xyz);

/* Graph thread. Fits the canonical face onto the newest tracked
 * landmarks and writes the head transform - canonical metric space
 * (centimeters) into frame pixels - as a column-major 4x4. Reports
 * GOSS_AGAIN until a face is tracked or while the fit is degenerate. */
goss_status goss_session_face_pose(goss_session *session, float *out_matrix);

/* Named attach points on the tracked face mesh for goss_session_face_region.
 * The left/right labels are the subject's own. */
#define GOSS_FACE_REGION_FOREHEAD 0u
#define GOSS_FACE_REGION_GLABELLA 1u
#define GOSS_FACE_REGION_NOSE_TIP 2u
#define GOSS_FACE_REGION_CHIN 3u
#define GOSS_FACE_REGION_LEFT_EYE 4u
#define GOSS_FACE_REGION_RIGHT_EYE 5u
#define GOSS_FACE_REGION_LEFT_CHEEK 6u
#define GOSS_FACE_REGION_RIGHT_CHEEK 7u
#define GOSS_FACE_REGION_LEFT_EAR 8u
#define GOSS_FACE_REGION_RIGHT_EAR 9u
#define GOSS_FACE_REGION_MOUTH_CENTER 10u
#define GOSS_FACE_REGION_LEFT_MOUTH_CORNER 11u
#define GOSS_FACE_REGION_RIGHT_MOUTH_CORNER 12u

/* Graph thread. Writes the newest tracked face's named region point (x, y in
 * frame pixels, z in the same scale) into out_xyz, so a lens pins content to
 * the forehead, a cheek, or the chin. GOSS_ERROR_INVALID_ARGUMENT on an
 * unknown region; GOSS_AGAIN with no face or presence below threshold. */
goss_status goss_session_face_region(goss_session *session, uint32_t region, float *out_xyz);

/* Effect identifiers for goss_session_set_beauty. Values clamp to zero and
 * one; zero disables the effect. */
#define GOSS_BEAUTY_SMOOTH 0
#define GOSS_BEAUTY_WHITEN 1
#define GOSS_BEAUTY_THIN_FACE 2
#define GOSS_BEAUTY_BIG_EYE 3
#define GOSS_BEAUTY_LIPSTICK 4
#define GOSS_BEAUTY_BLUSH 5

/* Graph thread. Stands the beauty chain up for a session. resource_path
 * names the directory holding the effect engine's shader and image
 * assets. Builds without the effects engine report unsupported. */
goss_status goss_session_enable_beauty(goss_session *session, const char *resource_path);
void goss_session_disable_beauty(goss_session *session);

/* Graph thread. Sets one beauty effect's strength; see the GOSS_BEAUTY_*
 * identifiers above. Reports GOSS_AGAIN until beauty is enabled. */
goss_status goss_session_set_beauty(goss_session *session, int32_t effect, float value);

/* Graph thread, web only. Uploads one of whiten's four lookup textures -
 * slot 0 gray, 1 origin, 2 skin, 3 custom. rgba is a caller-decoded
 * image; whiten stays inert until all four slots are loaded. Reports
 * GOSS_UNSUPPORTED on every other target, where whiten runs through the
 * native beauty engine instead. */
goss_status goss_session_set_beauty_lut(goss_session *session, int32_t slot, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Uploads lipstick's (GOSS_BEAUTY_LIPSTICK) or
 * blush's (GOSS_BEAUTY_BLUSH) own source image - caller-decoded the same
 * way goss_session_set_beauty_lut's rgba is. Reports GOSS_UNSUPPORTED on
 * every other target. */
goss_status goss_session_set_beauty_makeup_texture(goss_session *session, int32_t effect, const uint8_t *rgba, uint32_t width, uint32_t height);

/* Graph thread, web only. Feeds one frame's tracked face landmarks into
 * a session directly - there is no internal tracking worker to drive
 * GOSS_BEAUTY_THIN_FACE/GOSS_BEAUTY_BIG_EYE/GOSS_BEAUTY_LIPSTICK/GOSS_BEAUTY_BLUSH
 * on web (goss_session_enable_face_tracking reports GOSS_ERROR_UNSUPPORTED
 * there); the caller runs its own tracker and hands the result straight
 * in. points holds point_count * 3 floats (x, y in frame pixels, z in
 * the same scale, matching goss_face_result's own landmarks convention);
 * point_count must be GOSS_FACE_LANDMARK_COUNT, or zero to clear any
 * previously set landmarks (no face this frame). Reports GOSS_UNSUPPORTED
 * on every other target, where goss_session_track_frame feeds the same
 * effects instead. */
goss_status goss_session_set_face_landmarks(goss_session *session, const float *points, uint32_t point_count);

/* Web analysis-producer path: feeds a segmentation mask the web tracking
 * module computed into the session as the subject texture the blend and
 * mask channels sample. mask_len is mask_side * mask_side floats; zero
 * clears it. Unsupported off the web, where the in-engine worker runs. */
goss_status goss_session_set_segmentation_mask(goss_session *session, const float *mask, uint32_t mask_len);

/* The class channels the active lens samples, as a bitmask over the mask
 * channels (bit 0 person, bit 1 background, and so on). The web app uploads
 * exactly these class masks each frame; zero means only the subject mask. */
uint32_t goss_session_segmentation_channels(goss_session *session);

/* Web analysis-producer path: uploads one class channel's mask (mask_side *
 * mask_side floats) as the texture that channel's passes sample. channel
 * indexes the mask channels; channel 0 (person) rides the subject mask,
 * which clears the class channels, so upload the classes after it. */
goss_status goss_session_set_segmentation_class_mask(goss_session *session, uint32_t channel, const float *mask, uint32_t mask_len);

/* Graph thread. The CPU-copy path for a single-plane BGRA8/RGBA8 frame -
 * a canvas or video element's own byte buffer, with no native GPU handle
 * behind it the way goss_session_submit_frame's zero-copy path needs. Same
 * shape as goss_session_submit_frame_copy, one interleaved plane instead
 * of NV12's two. */
goss_status goss_session_submit_frame_rgba_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride);

/* What an opened clip is and where it is, so a host scrubbing a timeline reads it
 * rather than guessing from a frame count and an authored frame rate. */
typedef struct goss_clip_info {
    uint32_t width;
    uint32_t height;
    int64_t duration_us;
    int64_t position_us;  /* presentation time of the frame last submitted */
    uint32_t ended;       /* 1 once the stream ended and no seek reopened it */
} goss_clip_info;

/* Graph thread. Opens a clip as a source of frames for this session. The engine
 * decodes it and the host decides when each frame lands, so the graph is driven by
 * the clip rather than the clip being decorated onto a camera feed. */
goss_status goss_session_open_clip(goss_session *session, const uint8_t *path, size_t path_len, uint32_t *out_clip);

/* Graph thread. Decodes the clip's next frame and submits it as this session's
 * frame, through the same path a camera's bytes take, so the graph cannot tell
 * where it came from and a session needs no camera at all. Pass 0 for
 * timestamp_us to carry the clip's own presentation time. GOSS_AGAIN at the end of
 * the stream, so a host loops by seeking rather than reopening. */
goss_status goss_session_clip_submit_frame(goss_session *session, uint32_t clip, int64_t timestamp_us);

/* Graph thread. Moves to the keyframe at or before a time. Refused past the end
 * rather than clamped: a clamped seek returns the wrong frame silently. */
goss_status goss_session_clip_seek(goss_session *session, uint32_t clip, int64_t target_us);

goss_status goss_session_clip_info(goss_session *session, uint32_t clip, goss_clip_info *out_info);
goss_status goss_session_close_clip(goss_session *session, uint32_t clip);

/* Graph thread. Moves the clip by whole frames and leaves it on the one it lands
 * on. Forward is a decode; backward is a seek and a decode, because a
 * forward-only decoder cannot step back any other way. */
goss_status goss_session_clip_step(goss_session *session, uint32_t clip, int32_t frames);

/* What this build's media backend declares it encodes, as bit sets over the codec
 * and container enums, so a host asks rather than assuming from the platform. */
typedef struct goss_media_capabilities {
    uint32_t video_codecs;   /* bit per goss_video_codec */
    uint32_t audio_codecs;   /* bit per goss_audio_codec */
    uint32_t containers;     /* bit per goss_container */
    uint32_t max_width;
    uint32_t max_height;
    uint32_t max_bit_depth;
    uint32_t hdr;            /* 1 when a declared profile writes an hdr transfer */
    uint32_t zero_copy;      /* 1 when the backend takes a platform buffer */
} goss_media_capabilities;

/* Any thread. */
goss_status goss_engine_media_capabilities(goss_engine *engine, goss_media_capabilities *out_caps);

/* Which sections a perception snapshot should carry, as bits. An agent polling
 * every frame usually wants two of the twelve, and writing all of them to be
 * ignored is the cost this avoids. */
#define GOSS_PERCEPTION_FRAME (1u << 0)
#define GOSS_PERCEPTION_FACES (1u << 1)
#define GOSS_PERCEPTION_HANDS (1u << 2)
#define GOSS_PERCEPTION_BODIES (1u << 3)
#define GOSS_PERCEPTION_SEGMENTATION (1u << 4)
#define GOSS_PERCEPTION_WORLD (1u << 5)
#define GOSS_PERCEPTION_DEPTH (1u << 6)
#define GOSS_PERCEPTION_SCENE (1u << 7)
#define GOSS_PERCEPTION_TEXT (1u << 8)
#define GOSS_PERCEPTION_AUDIO (1u << 9)
#define GOSS_PERCEPTION_LENS (1u << 10)
#define GOSS_PERCEPTION_ENGINE (1u << 11)
#define GOSS_PERCEPTION_ALL 0xFFFu

/* Any thread. One versioned record of what the engine currently sees, written
 * into the caller's buffer. Every section carries its own tag, version and byte
 * length, so a consumer built against an older schema steps over a section it does
 * not know rather than failing. GOSS_AGAIN with out_len set to the size needed
 * when the buffer is short, so a caller sizes once rather than guessing. */
goss_status goss_session_perception_snapshot(goss_session *session, uint32_t select, uint8_t *out, size_t capacity, size_t *out_len);

/* Any thread. The same record as compact JSON, for the agent gateways that speak
 * it. Projected from the binary form rather than written a second time from the
 * session, so the two cannot drift. A section this build cannot name is reported
 * with its tag and byte length rather than dropped. */
goss_status goss_session_perception_json(goss_session *session, uint32_t select, uint8_t *out, size_t capacity, size_t *out_len);

/* What happened. Numbers are frozen once shipped: a consumer switches on these. */
typedef enum goss_event_kind {
    GOSS_EVENT_FACE_APPEARED = 1,
    GOSS_EVENT_FACE_LOST = 2,
    GOSS_EVENT_FACE_COUNT_CHANGED = 3,
    GOSS_EVENT_HAND_APPEARED = 4,
    GOSS_EVENT_HAND_LOST = 5,
    GOSS_EVENT_GESTURE_RECOGNISED = 6,
    GOSS_EVENT_BODY_APPEARED = 7,
    GOSS_EVENT_BODY_LOST = 8,
    GOSS_EVENT_ACTION_RECOGNISED = 9,
    GOSS_EVENT_TRACKING_STATE_CHANGED = 10,
    GOSS_EVENT_PLANE_ADDED = 11,
    GOSS_EVENT_PLANE_UPDATED = 12,
    GOSS_EVENT_ANCHOR_ADDED = 13,
    GOSS_EVENT_ANCHOR_LOST = 14,
    GOSS_EVENT_WORLD_MESH_UPDATED = 15,
    GOSS_EVENT_DETECTION_APPEARED = 16,
    GOSS_EVENT_DETECTION_LOST = 17,
    GOSS_EVENT_LABEL_CHANGED = 18,
    GOSS_EVENT_TEXT_APPEARED = 19,
    GOSS_EVENT_TEXT_CHANGED = 20,
    GOSS_EVENT_SEGMENTATION_CLASS_APPEARED = 21,
    GOSS_EVENT_AUDIO_BEAT = 22,
    GOSS_EVENT_VOICE_ACTIVITY_STARTED = 23,
    GOSS_EVENT_VOICE_ACTIVITY_ENDED = 24,
    GOSS_EVENT_LENS_ACTIVATED = 25,
    GOSS_EVENT_LENS_NODE_DEGRADED = 26,
    GOSS_EVENT_LENS_NODE_FAILED = 27,
    GOSS_EVENT_PARAMETER_CHANGED = 28,
    GOSS_EVENT_TRIGGER_FIRED = 29,
    GOSS_EVENT_DEGRADE_LEVEL_CHANGED = 30,
    GOSS_EVENT_POOL_EXHAUSTED = 31,
    GOSS_EVENT_RECORDING_STARTED = 32,
    GOSS_EVENT_RECORDING_PAUSED = 33,
    GOSS_EVENT_RECORDING_RESUMED = 34,
    GOSS_EVENT_RECORDING_STOPPED = 35,
    GOSS_EVENT_INTERRUPTION = 36,
    GOSS_EVENT_FRAME_DROPPED = 37,
    GOSS_EVENT_BUDGET_EXCEEDED = 38,
    GOSS_EVENT_THERMAL_CHANGED = 39,
} goss_event_kind;

/* One thing that happened. Plain data and fixed size: an event carrying a pointer
 * would outlive what it points at. What a and b mean is per kind. */
typedef struct goss_event {
    uint32_t kind;
    uint64_t sequence;   /* monotonic per session, so a gap is visible */
    int64_t timestamp_us;
    uint32_t a;
    uint32_t b;
    float value;
} goss_event;

/* Any thread. Drains the session's bounded event ring in order. out_dropped says
 * whether anything was missed since the last drain and is cleared by the read, so
 * a consumer sees each drop once rather than the same number for ever. */
goss_status goss_session_poll_events(goss_session *session, goss_event *out, uint32_t capacity, uint32_t *out_count, uint64_t *out_dropped);

/* When an egress frame is worth sending. Combinable: "every keyframe, plus
 * anything that changed, plus anything an event touched" is one policy. */
#define GOSS_EGRESS_ALWAYS (1u << 0)
#define GOSS_EGRESS_ON_CHANGE (1u << 1)
#define GOSS_EGRESS_ON_EVENT (1u << 2)
#define GOSS_EGRESS_ON_INTERVAL (1u << 3)
#define GOSS_EGRESS_ON_REQUEST (1u << 4)

typedef enum goss_egress_format {
    GOSS_EGRESS_JPEG = 0, GOSS_EGRESS_PNG = 1, GOSS_EGRESS_WEBP = 2,
    GOSS_EGRESS_RGBA = 3, GOSS_EGRESS_NV12 = 4,
} goss_egress_format;

typedef enum goss_egress_source {
    GOSS_EGRESS_COMPOSITED = 0, GOSS_EGRESS_CAMERA = 1, GOSS_EGRESS_NAMED_SOURCE = 2,
    GOSS_EGRESS_NAMED_SCREEN = 3, GOSS_EGRESS_SEGMENTATION_MASK = 4, GOSS_EGRESS_DEPTH = 5,
} goss_egress_source;

/* Why a frame was or was not sent, so a gateway can explain itself. */
typedef enum goss_egress_reason {
    GOSS_EGRESS_SENT_ALWAYS = 0, GOSS_EGRESS_SENT_CHANGED = 1, GOSS_EGRESS_SENT_EVENT = 2,
    GOSS_EGRESS_SENT_INTERVAL = 3, GOSS_EGRESS_SENT_REQUESTED = 4,
    GOSS_EGRESS_HELD_RATE = 5, GOSS_EGRESS_HELD_BYTES = 6,
    GOSS_EGRESS_HELD_UNCHANGED = 7, GOSS_EGRESS_HELD_NO_TRIGGER = 8,
} goss_egress_reason;

typedef struct goss_egress_config {
    uint32_t target_long_edge;   /* 0 means no scaling */
    uint32_t format;
    uint32_t quality;            /* 1..100 for the lossy formats */
    uint32_t max_fps;            /* 0 means no ceiling */
    uint64_t max_bytes_per_second;
    uint32_t source;
    uint32_t trigger;            /* GOSS_EGRESS_* bits */
    float change_threshold;      /* 0..1 */
    int64_t keyframe_interval_us;
} goss_egress_config;

typedef struct goss_egress_decision {
    uint32_t send;
    uint32_t reason;
    float change_score;
    int64_t since_last_us;
    uint64_t sent_total;
    uint64_t held_total;
} goss_egress_decision;

/* Graph thread. Installs the policy; a configuration outside its own ranges is
 * refused rather than producing a stream nobody can explain. */
goss_status goss_session_egress_configure(goss_session *session, const goss_egress_config *config);

/* Graph thread. The host asking for one frame whatever the change score says. */
goss_status goss_session_egress_request(goss_session *session);

/* Graph thread. Whether this frame is worth sending, and why. The score is
 * measured on a luma grid, so a still room costs a grid comparison rather than an
 * encode. GOSS_AGAIN when there are no pixels to score. */
goss_status goss_session_egress_decide(goss_session *session, goss_egress_decision *out_decision);

/* What an agent draws back into the frame. */
typedef enum goss_annotation_kind {
    GOSS_ANNOTATION_BOX = 1, GOSS_ANNOTATION_LABEL = 2, GOSS_ANNOTATION_POINT = 3,
    GOSS_ANNOTATION_ARROW = 4, GOSS_ANNOTATION_PATH = 5, GOSS_ANNOTATION_HIGHLIGHT = 6,
    GOSS_ANNOTATION_MASK_OVERLAY = 7, GOSS_ANNOTATION_IMAGE = 8, GOSS_ANNOTATION_METER = 9,
} goss_annotation_kind;

/* What an annotation is positioned against. A box in screen space and a box bound
 * to a face are one annotation with different anchors. */
typedef enum goss_anchor_space {
    GOSS_ANCHOR_SCREEN = 0, GOSS_ANCHOR_PIXELS = 1, GOSS_ANCHOR_WORLD = 2,
    GOSS_ANCHOR_TRACK = 3, GOSS_ANCHOR_FACE_REGION = 4,
} goss_anchor_space;

/* What happens when the thing an annotation follows goes away. Stated rather than
 * assumed: a label that outlives its face is the commonest overlay bug. */
typedef enum goss_on_lost { GOSS_ON_LOST_REMOVE = 0, GOSS_ON_LOST_HOLD = 1, GOSS_ON_LOST_FADE = 2 } goss_on_lost;

typedef enum goss_lifetime_kind {
    GOSS_LIFETIME_EXPLICIT = 0, GOSS_LIFETIME_FRAMES = 1,
    GOSS_LIFETIME_DURATION = 2, GOSS_LIFETIME_TRACK = 3,
} goss_lifetime_kind;

typedef struct goss_annotation {
    uint32_t id;
    uint32_t kind;
    uint32_t space;
    float rect[4];
    uint32_t track_id;
    uint8_t colour[4];
    int32_t z;
    float opacity;
    uint32_t lifetime_kind;
    int64_t lifetime_value;  /* frame count or microseconds */
    uint32_t on_lost;
    float value;
} goss_annotation;

/* Graph thread. Adds or updates one annotation; the same id replaces rather than
 * duplicating, so an agent moves one box every frame without leaking an entry per
 * frame. GOSS_ERROR_POOL_EXHAUSTED when the bounded set is full. */
goss_status goss_session_annotate(goss_session *session, const goss_annotation *annotation, const uint8_t *text, size_t text_len);
goss_status goss_session_annotation_remove(goss_session *session, uint32_t id);
goss_status goss_session_annotation_clear(goss_session *session);

/* Any thread. How many are live, and how many adds the bound turned away, which is
 * what tells an agent its overlay is losing annotations. */
goss_status goss_session_annotation_count(goss_session *session, uint32_t *out_count, uint64_t *out_refused);

/* Graph thread. Multi-source composition (Duet, Stitch, live grids). Register a
 * named RGBA source with define_source, feed it with submit_source_frame_rgba_copy,
 * then set_layout to composite the camera (source 0) and the named sources
 * (arrangement: 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid, 5 overlay,
 * where every source covers the whole frame and stacks by opacity). */
goss_status goss_session_define_source(goss_session *session, const uint8_t *name, size_t name_len);
goss_status goss_session_remove_source(goss_session *session, const uint8_t *name, size_t name_len);
goss_status goss_session_submit_source_frame_rgba_copy(goss_session *session, const uint8_t *name, size_t name_len, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride);

/* Graph thread. Hands a named source one BGRA or RGBA frame zero-copy: the one
 * plane is a platform texture wrapped, not read, the way the camera's own frame
 * is, so a second lens composites at no per-frame copy. The platform object must
 * outlive the next rendered frame. */
goss_status goss_session_submit_source_frame(goss_session *session, const uint8_t *name, size_t name_len, const goss_frame_desc *desc, const goss_frame_planes *planes);
goss_status goss_session_set_layout(goss_session *session, uint32_t arrangement);
goss_status goss_session_clear_layout(goss_session *session);
/* arrangement 5 overlay stacks the sources full-frame over each other. A source
 * composites with a per-source blend: opacity, key_mode 1 mattes from the
 * source alpha, key_mode 2 chroma-keys against (key_r,key_g,key_b) by color
 * distance with a similarity threshold, key_mode 3 keys by a supplied per-source
 * mask (submit_source_mask); the name "camera" addresses the base (no mode 3).
 * A screen-share source letterboxes to fit its cell instead of stretching. */
goss_status goss_session_set_source_composite(goss_session *session, const uint8_t *name, size_t name_len, float opacity, uint32_t key_mode, float key_r, float key_g, float key_b, float similarity);
/* Uploads a per-source matte for key_mode 3: an RGBA image whose red channel is
 * the mask (1 keeps the source, 0 cuts it), resampled to the source's cell, so
 * an opaque guest is keyed to a subject without a baked alpha. The bytes are
 * copied; the camera and an unknown source are rejected. */
goss_status goss_session_submit_source_mask(goss_session *session, const uint8_t *name, size_t name_len, const uint8_t *rgba, uint32_t width, uint32_t height);
/* Runs the engine's own segmenter on a named source's frames, so the subject
 * mask that feeds its key_mode 3 matte is computed on-device with no host
 * segmenter (a virtual background for a remote guest). model_bytes is the same
 * selfie/hair model enable_segmentation takes and must pass the digest allow
 * list when one is set; model_len 0 tears the source segmenter down. */
goss_status goss_session_enable_source_segmentation(goss_session *session, const uint8_t *name, size_t name_len, const uint8_t *model_bytes, size_t model_len, int32_t threads);
goss_status goss_session_define_screen_share(goss_session *session, const uint8_t *name, size_t name_len);

/* Graph thread. Geofilters: location-gated overlay lenses. set_geofence sets a
 * circle the app derives from a lens's intended place; submit_location feeds a
 * fix. The engine computes geo.in_region on-device and only that boolean
 * crosses the trigger rail, so the location never leaves the process. */
goss_status goss_session_submit_location(goss_session *session, double latitude, double longitude, float horizontal_accuracy_m, int64_t timestamp_us);
goss_status goss_session_set_geofence(goss_session *session, double latitude, double longitude, double radius_m);
goss_status goss_session_clear_geofence(goss_session *session);
/* A geofence may instead be an axis-aligned box or a polygon ring (vertex_count
 * lat, lon pairs, three to 64 vertices). An accuracy gate refuses a fix vaguer
 * than max_accuracy_m so a lens does not fire on an uncertain location; zero
 * clears the gate. */
goss_status goss_session_set_geofence_bbox(goss_session *session, double min_lat, double min_lon, double max_lat, double max_lon);
goss_status goss_session_set_geofence_polygon(goss_session *session, const double *coords, size_t vertex_count);
goss_status goss_session_set_geo_accuracy(goss_session *session, float max_accuracy_m);
/* Named circular geofences alongside the single default one, so a lens fires
 * geo.in_region('name') for its own place among several. Re-adding a name
 * replaces its region; the name is copied. clear_named_geofences empties the
 * set and leaves the default geofence untouched. */
goss_status goss_session_set_named_geofence(goss_session *session, const uint8_t *name, size_t name_len, double latitude, double longitude, double radius_m);
/* A named polygon geofence: the region is a ring of three or more (lat, lon)
 * pairs, the non-circular counterpart of set_geofence_polygon for named
 * regions. Re-adding a name replaces its region; the name is copied. */
goss_status goss_session_set_named_geofence_polygon(goss_session *session, const uint8_t *name, size_t name_len, const double *coords, size_t vertex_count);
goss_status goss_session_clear_named_geofences(goss_session *session);

/* Brush board. The engine owns stroke state and the undo/redo stacks; the app
 * feeds points in normalized screen space and pulls the finished triangle
 * ribbon (x, y, r, g, b, a per vertex) for the renderer to draw. brush_vertices
 * with a null out reports the float count the caller must size for. */
goss_status goss_session_brush_set_style(goss_session *session, float r, float g, float b, float a, float width);
/* Uploads the RGBA sprite a stamp-mode stroke (brush mode 4) lays along its
 * length, an emoji or icon the host rasterizes; the bytes are copied. A stamp
 * stroke draws nothing until one is set. */
goss_status goss_session_brush_set_stamp(goss_session *session, const uint8_t *rgba, uint32_t width, uint32_t height);
goss_status goss_session_brush_begin(goss_session *session);
goss_status goss_session_brush_point(goss_session *session, float x, float y);
goss_status goss_session_brush_end(goss_session *session);
goss_status goss_session_brush_undo(goss_session *session);
goss_status goss_session_brush_redo(goss_session *session);
goss_status goss_session_brush_clear(goss_session *session);
goss_status goss_session_brush_vertices(goss_session *session, float *out, size_t capacity_floats, size_t *out_count);
/* Brush preset for the next stroke: 0 pen, 1 highlighter, 2 marker, 3 neon
 * (drawn additively), 4 stamp (lays the brush_set_stamp sprite along the
 * stroke). Erase removes committed strokes within radius of a point, refusing
 * mid-stroke, and reports the count. */
goss_status goss_session_brush_set_mode(goss_session *session, uint32_t mode);
goss_status goss_session_brush_erase_at(goss_session *session, float x, float y, float radius, size_t *out_removed);

/* World-anchored brush. Points are pushed in the world frame the platform world
 * tracking reports poses in; the engine projects them through the camera pose
 * each frame and draws them like the screen brush, so a stroke stays fixed in
 * the scene. Nothing draws without live world tracking. */
goss_status goss_session_ar_brush_set_style(goss_session *session, float r, float g, float b, float a, float width);
goss_status goss_session_ar_brush_set_mode(goss_session *session, uint32_t mode);
goss_status goss_session_ar_brush_begin(goss_session *session);
goss_status goss_session_ar_brush_point(goss_session *session, float x, float y, float z);
goss_status goss_session_ar_brush_end(goss_session *session);
goss_status goss_session_ar_brush_undo(goss_session *session);
goss_status goss_session_ar_brush_redo(goss_session *session);
goss_status goss_session_ar_brush_clear(goss_session *session);

/* Screen touch. Feed one event per finger so the engine recognizes the screen
 * gestures a lens reacts to and the pointer position. phase is 0 began, 1
 * moved, 2 ended, 3 cancelled; pointer_id names the finger; x and y are
 * normalized 0..1. Recognized gestures reach the lens at the next tick. */
goss_status goss_session_touch(goss_session *session, uint32_t phase, uint32_t pointer_id, float x, float y);

/* Haptics. A haptic trigger queues a device buzz each tick; drain them in a
 * loop after goss_session_tick_lens until GOSS_AGAIN and play each on the
 * platform. out_style is the style (0 light, 1 medium, 2 heavy, 3 soft, 4
 * rigid, 5 success, 6 warning, 7 failure); out_intensity is a 0..1 hint. */
goss_status goss_session_pull_haptic(goss_session *session, uint32_t *out_style, float *out_intensity);

/* The photosensitivity risk (0..1) the flash detector last reported for the
 * frames this session was fed, the same value a lens reads as safety.flash_risk.
 * The host shows its warning from it; the engine only measures. */
goss_status goss_session_flash_risk(goss_session *session, float *out_risk);

/* Grab and throw. goss_session_grab moves the nearest dynamic physics body to a
 * world point and, while it holds one, drags it there; the body is driven
 * kinematically each tick so it follows the pointer and gathers the velocity it
 * throws with. goss_session_release lets it go back to dynamic, flinging it. */
goss_status goss_session_grab(goss_session *session, float x, float y, float z);
goss_status goss_session_release(goss_session *session);

/* Live 2D colliders. goss_session_add_collider drops a static sphere collider
 * at a world point that dynamic content lands on at once; drawing them in as a
 * pointer moves builds a live 2D world. goss_session_erase_collider removes
 * every collider within radius of a point - the eraser. */
goss_status goss_session_add_collider(goss_session *session, float x, float y, float z);
goss_status goss_session_erase_collider(goss_session *session, float x, float y, float z, float radius);

/* Graph thread. Runs the beauty chain over one RGBA frame on the calling
 * thread, reading the newest tracking result for the landmark driven
 * effects when face tracking is enabled. The stated CPU path; live
 * preview integration on the render thread is the device side of this
 * row. */
goss_status goss_session_beautify_frame(goss_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out);

/* Graph thread. Replaces any currently active lens (unsplicing it first)
 * with the one manifest_json describes, splices its node subgraph into
 * the session's frame graph, and applies its default effect values to
 * the beauty chain if one is enabled. The bytes are copied; the caller
 * may release them on return. A manifest that fails to parse, or that
 * names a node type this build does not support, activates nothing and
 * reports GOSS_INVALID_ARGUMENT. */
goss_status goss_session_activate_lens(goss_session *session, const uint8_t *manifest_json, size_t manifest_len);

/* Graph thread. Same activation goss_session_activate_lens performs, from
 * bundle_path/manifest.json, plus one further step that function cannot
 * do without a bundle path to read from: a bgfx program is created for
 * every shader.pass node the lens splices, loading whichever compiled
 * variant under bundle_path/shaders/ matches the running platform's
 * active graphics backend. A shader failing to load leaves that one
 * pass without a program rather than failing the whole activation - a
 * packaged bundle was already proven to compile by the validator, so a
 * load failure here is a runtime anomaly, not an authoring error. */
goss_status goss_session_activate_lens_from_directory(goss_session *session, const uint8_t *bundle_path, size_t bundle_path_len);

/* Compiles a text prompt into a GLF lens manifest on device, writing it into
 * out_buf and its byte length into out_len. A NULL out_buf (or too small an
 * out_cap) reports the length only, so the caller sizes a buffer and calls
 * again, then inspects, saves, or activates the result with no assets needed. */
goss_status goss_compile_prompt(goss_engine *engine, const uint8_t *prompt, size_t prompt_len, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Composes an on-device generative-music track from a text prompt into a mono
 * 16-bit WAV in out_buf, its length in out_len; a NULL out_buf reports the
 * length only. A non-zero seed varies the take, bars 0 the default length.
 * Deterministic, no model; an external model feeds the same WAV path. */
goss_status goss_engine_generate_song(goss_engine *engine, const uint8_t *prompt, size_t prompt_len, uint32_t sample_rate, uint32_t seed, uint32_t bars, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Scans a width*height 8-bit luminance frame for an EAN-13 / UPC-A barcode and,
 * on the first row that decodes, writes its 13 digits (0..9) into out_digits and
 * returns GOSS_OK; GOSS_AGAIN when no row carries a checksum-valid symbol. Purely
 * algorithmic and deterministic, no model. */
goss_status goss_engine_scan_barcode(goss_engine *engine, const uint8_t *luminance, uint32_t width, uint32_t height, uint8_t *out_digits);

/* Scans a width*height 8-bit luminance frame for a QR code (versions 1-4, level
 * L, byte mode) and writes its decoded payload into out_buf with the length in
 * out_len, returning GOSS_OK; GOSS_AGAIN when no QR decodes. Reed-Solomon error
 * correction, algorithmic and deterministic, no model. A NULL out_buf reports
 * the length only. */
goss_status goss_engine_scan_qr(goss_engine *engine, const uint8_t *luminance, uint32_t width, uint32_t height, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Generates a QR code for a payload and renders it into an 8-bit luminance image
 * (0 dark, 255 light) of side out_dim, at module_scale pixels per module with a
 * quiet_modules-wide light border. A NULL out_buf reports the side only, so the
 * caller sizes a buffer and calls again. Algorithmic, deterministic, no model. */
goss_status goss_engine_generate_qr(goss_engine *engine, const uint8_t *payload, size_t payload_len, uint32_t module_scale, uint32_t quiet_modules, uint8_t *out_buf, size_t out_cap, uint32_t *out_dim);

/* Ranks a media archive by semantic similarity. corpus holds count embedding
 * vectors of length dim contiguously and query is one dim-vector, all from the
 * host's bring-your-own embedding model. Writes up to k winners into
 * out_indices with their cosine scores into out_scores and the count into
 * out_count. The engine owns the exact k-nearest search; any embedder feeds it. */
goss_status goss_engine_media_search(goss_engine *engine, const float *corpus, uint32_t count, uint32_t dim, const float *query, uint32_t k, uint32_t *out_indices, float *out_scores, uint32_t *out_count);

/* Seals a media blob for the on-device vault: encrypts plaintext under the
 * 32-byte key and 12-byte nonce with ChaCha20-Poly1305, binding aad, writing
 * ciphertext-then-tag into out_buf. A NULL out_buf reports the sealed length
 * (plaintext_len + 16) only. The host holds the key in the platform keystore. */
goss_status goss_seal_media(const uint8_t *key, const uint8_t *nonce, const uint8_t *plaintext, size_t plaintext_len, const uint8_t *aad, size_t aad_len, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Opens a sealed vault blob back to plaintext under the same key, nonce, and
 * aad. A NULL out_buf reports the plaintext length (sealed_len - 16) only.
 * Returns GOSS_INVALID_ARGUMENT if authentication fails, so a tampered or
 * forged blob never decodes. */
goss_status goss_open_media(const uint8_t *key, const uint8_t *nonce, const uint8_t *sealed, size_t sealed_len, const uint8_t *aad, size_t aad_len, uint8_t *out_buf, size_t out_cap, size_t *out_len);

/* Picks the best frame of a burst for computational capture: count luminance
 * frames of width*height, frame_stride bytes apart, scored by normalized
 * sharpness blended with a host openness score per frame (eyes-open, smile)
 * weighted by openness_weight in 0..1. Writes the winning frame index into
 * out_index, so best-take fusion keeps the crisp, eyes-open shot on device. */
goss_status goss_engine_best_take(goss_engine *engine, const uint8_t *frames, size_t frame_stride, uint32_t count, uint32_t width, uint32_t height, const float *openness, float openness_weight, uint32_t *out_index);

/* Graph thread. Unsplices the active lens and frees everything its
 * activation allocated. Accepts no active lens and does nothing. */
void goss_session_deactivate_lens(goss_session *session);

/* Graph thread. Advances the active lens by dt_us of real time,
 * evaluating its compiled triggers against signals and applying every
 * effect value that changed as a result to the beauty chain, if one is
 * enabled. Reports GOSS_AGAIN with no active lens. */
goss_status goss_session_tick_lens(goss_session *session, uint32_t dt_us, const goss_lens_signals *signals);

/* Graph thread. Fires a named event the next goss_session_tick_lens delivers
 * to the lens's event('name') triggers for exactly one tick, then clears -
 * drives an on-screen effect from an app moment; the engine knows the name,
 * never its meaning. Buffered without allocation; over-long names truncate. */
goss_status goss_session_fire_event(goss_session *session, const uint8_t *name, size_t name_len);

/* Graph thread. Reads a live parameter of the active lens by name,
 * including whatever a script node last wrote, into out_value. Reports
 * GOSS_AGAIN with no active lens and GOSS_INVALID_ARGUMENT for an unknown
 * name. */
goss_status goss_session_parameter_value(goss_session *session, const uint8_t *name, size_t name_len, float *out_value);

/* Graph thread. Pulls the next block of mixed lens audio (frames * channels
 * interleaved s16) that play_sound triggers produced, for the SDK to hand to
 * the platform audio output. Writes silence when no lens sound is active. */
goss_status goss_session_pull_audio(goss_session *session, int16_t *out, uint32_t frames);

/* Graph thread. Reads the latest caption an audio.infer node CTC-decoded, by the
 * node's id. Writes up to capacity bytes of UTF-8 into out and the full length
 * into out_len (so a caller can size a buffer). Returns goss_status_again when
 * the named node has no caption binding or has decoded nothing yet. */
goss_status goss_session_caption_text(goss_session *session, const uint8_t *node_id, size_t node_id_len, uint8_t *out, size_t capacity, size_t *out_len);

/* One diarized caption segment: the times it spanned, the speaker who spoke it
 * (a diarize binding's clustered id), and the byte length of its text (read
 * through goss_session_caption_segment_text). Layout: 24 bytes. */
typedef struct goss_caption_segment {
    int64_t start_us;
    int64_t end_us;
    uint32_t speaker;
    uint32_t text_len;
} goss_caption_segment;

/* Graph thread. Reads one recent diarized caption segment by index (0 the
 * newest) into out; the text comes through goss_session_caption_segment_text.
 * Returns goss_status_again when the index is past the segments held. */
goss_status goss_session_caption_segment(goss_session *session, uint32_t index, goss_caption_segment *out);

/* Graph thread. Reads one recent diarized caption segment's UTF-8 text by index
 * (0 the newest), up to capacity bytes into out with the full length in out_len.
 * Returns goss_status_again when the index is past the segments held. */
goss_status goss_session_caption_segment_text(goss_session *session, uint32_t index, uint8_t *out, size_t capacity, size_t *out_len);

/* Graph thread. Enables (non-zero) or disables on-device dubbing: when on, a
 * dub-bound audio.infer node synthesizes its decoded caption or translation to
 * speech and plays it into the lens mixer. Off by default. */
goss_status goss_session_set_dubbing(goss_session *session, uint32_t enabled);

/* Graph thread. Folds the active lens sound into the caller's outgoing
 * call/live track: mic (interleaved f32 at sample_rate/channels, or NULL for
 * silence) summed with the 48 kHz mono lens mixer resampled to that rate, into
 * out (frame_count*channels s16). Advances the mixer once, replacing pull_audio. */
goss_status goss_session_mix_output_audio(goss_session *session, const float *mic, int16_t *out, uint32_t frame_count, uint32_t sample_rate, uint32_t channels);

/* Graph thread. Releases one solver hair by the id the session's physics
 * world assigned it, pairing the acquire a hair lens performs at activation,
 * so a hair can retire mid-session without tearing the world down. Reports
 * GOSS_AGAIN with no physics world and GOSS_INVALID_ARGUMENT for an id that
 * is unknown or already removed. */
goss_status goss_physics_hair_remove(goss_session *session, uint32_t hair_id);

/* Render thread. Releases the persistent external-texture wrap
 * goss_engine_render_to_live_texture keeps per native handle, for a host
 * retiring a publish surface before the engine goes away. Reports
 * GOSS_INVALID_ARGUMENT for a handle with no live wrap. */
goss_status goss_engine_release_live_texture(goss_engine *engine, uint64_t native_handle);

/* Any thread. Fingerprints a reference recording (interleaved f32 at
 * sample_rate/channels) and registers it under track_id in the engine's
 * on-device music catalog. Model-free; re-adding a track_id layers more
 * landmarks in, so a longer reference can be built from several passes. */
goss_status goss_engine_music_add_reference(goss_engine *engine, uint32_t track_id, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels);

/* Any thread. Empties the engine's music catalog. */
void goss_engine_music_clear_references(goss_engine *engine);

/* Any thread. Fingerprints a captured snippet and matches it against the
 * catalog, writing the best track id to out_track_id and its landmark-agreement
 * vote count to out_votes. A vote count of zero means no track met min_votes.
 * The match is the track and time offset the snippet most agrees on, so a few
 * seconds of noisy audio still identifies. */
goss_status goss_engine_music_identify(goss_engine *engine, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels, uint32_t min_votes, uint32_t *out_track_id, uint32_t *out_votes);

/* Any thread. Walks a whole buffer through the same energy-flux onset detector
 * the audio.beat trigger rides and writes the time of every beat, in
 * microseconds from the buffer's start, into out_times_us (up to capacity).
 * out_count always receives the full number found, so a caller can size a
 * buffer and ask again. Deterministic for the same samples. */
goss_status goss_engine_beat_map(goss_engine *engine, const float *samples, uint32_t frame_count, uint32_t sample_rate, uint32_t channels, int64_t *out_times_us, uint32_t capacity, uint32_t *out_count);

#if !defined(__cplusplus) && (__STDC_VERSION__ >= 201112L)
_Static_assert(sizeof(goss_frame_desc) == 32, "goss_frame_desc layout is frozen");
_Static_assert(sizeof(goss_landmarks) == 24, "goss_landmarks layout is frozen");
_Static_assert(sizeof(goss_engine_config) == 8, "goss_engine_config layout is frozen");
_Static_assert(sizeof(goss_session_config) == 8, "goss_session_config layout is frozen");
_Static_assert(sizeof(goss_face_result) == 5968, "goss_face_result layout is frozen");
_Static_assert(offsetof(goss_face_result, landmarks) == 24, "goss_face_result layout is frozen");
_Static_assert(sizeof(goss_hand) == 268, "goss_hand layout is frozen");
_Static_assert(sizeof(goss_hand_result) == 560, "goss_hand_result layout is frozen");
_Static_assert(offsetof(goss_hand_result, hands) == 24, "goss_hand_result layout is frozen");
_Static_assert(sizeof(goss_pose_result) == 688, "goss_pose_result layout is frozen");
_Static_assert(offsetof(goss_pose_result, landmarks) == 24, "goss_pose_result layout is frozen");
_Static_assert(sizeof(goss_renderer_desc) == (sizeof(void *) == 8 ? 16 : 12), "goss_renderer_desc layout is frozen");
_Static_assert(sizeof(goss_frame_planes) == 32, "goss_frame_planes layout is frozen");
_Static_assert(sizeof(goss_lens_signals) == 232, "goss_lens_signals layout is frozen");
_Static_assert(sizeof(goss_camera_controls) == 56, "goss_camera_controls layout is frozen");
_Static_assert(sizeof(goss_recording_policy) == 40, "goss_recording_policy layout is frozen");
_Static_assert(sizeof(goss_capture_ui) == 40, "goss_capture_ui layout is frozen");
_Static_assert(offsetof(goss_lens_signals, world_tracking_state) == 8, "goss_lens_signals layout is frozen");
_Static_assert(offsetof(goss_lens_signals, blendshapes) == 24, "goss_lens_signals layout is frozen");
#endif

#ifdef __cplusplus
}
#endif

#endif /* GOSSLENS_H */
