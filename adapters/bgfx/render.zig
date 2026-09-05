//! The render backend node: the one binding over bgfx. Owns renderer
//! lifecycle, the preview pipeline, and shader assembly. SDKs hand over a
//! native surface and zero-copy camera textures; everything after that
//! happens here. Frame-path work allocates nothing after the pipelines are
//! built: transient quad vertices come from bgfx's bounded pools.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("math");
const image = @import("image");
const blobs = @import("shader_blobs");
const makeup_mesh = @import("makeup_mesh");
const face_mesh_topology = @import("face_mesh_topology");
const lash_mesh = @import("lash_mesh");

/// How many lash strands the fragment stage combs across one eye's strip,
/// and how soft each strand's edge is - the look shared by every lash draw.
const lash_strand_count: f32 = 14.0;
const lash_edge_softness: f32 = 0.35;

pub const android_vk = if (builtin.os.tag == .linux and builtin.abi.isAndroid())
    @import("android_vk.zig")
else
    struct {};

pub const c = @cImport({
    @cInclude("bgfx/c99/bgfx.h");
});

pub const invalid_handle: u16 = std.math.maxInt(u16);

/// fs_beauty_reshape.sc packs the 106-point base face contour two
/// points per vec4 uniform - thin_face/big_eye only ever index into
/// that base range, never the five derived hub points face106.zig
/// appends for lipstick/blush's own mesh.
pub const face_point_vec4_count = 53;

/// fs_reshape_bank.sc packs its sixty-six per-region sculpt amounts four per
/// vec4 into u_reshapeBank, so seventeen vec4s cover them with two slots to
/// spare, indexed only by compile-time constants for essl safety.
pub const face_reshape_bank_vec4_count = 17;

/// fs_reshape_body.sc packs six pose points two per vec4 into u_bodyPoints and
/// its eleven body sculpt amounts four per vec4 into u_bodyBank.
pub const body_reshape_points_vec4_count = 3;
pub const body_reshape_bank_vec4_count = 3;

/// A named alias for bgfx's own texture handle, matching the stub
/// module's TextureHandle - lets callers that need to name the type
/// (a hashmap value type, say) write render.TextureHandle uniformly
/// against whichever module is actually linked in.
pub const TextureHandle = c.bgfx_texture_handle_t;

/// The affine color conversion as one homogeneous matrix for the shader.
fn yuvTransform(conversion: math.color.Conversion) math.Mat4 {
    return conversion.homogeneous();
}

pub const InitOptions = struct {
    native_window_handle: ?*anyopaque,
    width: u32,
    height: u32,
    callback: ?*c.bgfx_callback_interface_t = null,
    vsync: bool = true,
};

/// The engine-owned diagnostics interface (adapters/bgfx/callbacks.c):
/// fatal and trace route to stderr. Installed by init whenever the host
/// passes no callback of its own, so every production SDK gets it.
extern fn goss_bgfx_callbacks() [*c]c.bgfx_callback_interface_t;

pub const Nv12Textures = struct {
    y: c.bgfx_texture_handle_t,
    uv: c.bgfx_texture_handle_t,
};

const UploadCache = struct {
    y: c.bgfx_texture_handle_t,
    uv: c.bgfx_texture_handle_t,
    width: u16,
    height: u16,
};

const RgbaUploadCache = struct {
    texture: c.bgfx_texture_handle_t,
    width: u16,
    height: u16,
    format: u32,
};

pub const PreviewFrame = union(enum) {
    bgra: struct {
        texture: c.bgfx_texture_handle_t,
    },
    nv12: struct {
        y: c.bgfx_texture_handle_t,
        uv: c.bgfx_texture_handle_t,
        conversion: math.color.Conversion,
    },
};

const is_android = builtin.os.tag == .linux and builtin.abi.isAndroid();

const VkZeroCopy = if (is_android) struct {
    converter: android_vk.Converter,
    textures: [android_vk.ring_depth]c.bgfx_texture_handle_t = @splat(.{ .idx = invalid_handle }),
    width: u32 = 0,
    height: u32 = 0,
    /// Beauty compositing's Vulkan-side imports: write side and read
    /// side.
    beauty_render_target: android_vk.BeautyRenderTarget = .{},
    beauty_import: android_vk.BeautyImport = .{},
} else struct {};

/// A small ring of persistent CPU buffers a per-frame upload references
/// through bgfx_make_ref: a slot is not reused until the ring cycles past
/// it, by which point bgfx has consumed the reference. Grown on a size
/// change; the growth lands in warm-up, never on the steady frame path.
const UploadRing = struct {
    slots: [3][]u8 = .{ &.{}, &.{}, &.{} },
    capacity: usize = 0,
    cursor: usize = 0,

    fn next(self: *UploadRing, gpa: std.mem.Allocator, bytes: usize) ?[]u8 {
        if (bytes > self.capacity) {
            for (&self.slots) |*slot| {
                const grown = gpa.alloc(u8, bytes) catch return null;
                if (slot.len != 0) gpa.free(slot.*);
                slot.* = grown;
            }
            self.capacity = bytes;
        }
        const slot = self.slots[self.cursor][0..bytes];
        self.cursor = (self.cursor + 1) % self.slots.len;
        return slot;
    }

    fn deinit(self: *UploadRing, gpa: std.mem.Allocator) void {
        for (&self.slots) |*slot| if (slot.len != 0) gpa.free(slot.*);
        self.* = .{};
    }
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    /// Reused CPU staging for dynamic-mesh uploads: positions padded to the
    /// shared vertex layout. Grown to the largest mesh then reused every
    /// frame, freed in deinit - the update path never allocates after warmup.
    interleave_scratch: []f32 = &.{},
    /// Persistent CPU rings the camera-upload paths reference through
    /// bgfx_make_ref rather than a per-frame bgfx_alloc; each slot outlives
    /// the frames bgfx needs it, grown on a size change, freed in deinit.
    nv12_ring: UploadRing = .{},
    rgba_ring: UploadRing = .{},
    zero_copy: ?VkZeroCopy = null,
    width: u32,
    height: u32,
    layout: c.bgfx_vertex_layout_t,
    lit_model_layout: c.bgfx_vertex_layout_t,
    billboard_layout: c.bgfx_vertex_layout_t,
    brush_layout: c.bgfx_vertex_layout_t,
    rgba_program: c.bgfx_program_handle_t,
    nv12_program: c.bgfx_program_handle_t,
    lut_program: c.bgfx_program_handle_t,
    blend_program: c.bgfx_program_handle_t,
    blend_params_uniform: c.bgfx_uniform_handle_t,
    blur_program: c.bgfx_program_handle_t,
    dof_program: c.bgfx_program_handle_t,
    fog_program: c.bgfx_program_handle_t,
    outline_program: c.bgfx_program_handle_t,
    tint_program: c.bgfx_program_handle_t,
    occluder_program: c.bgfx_program_handle_t,
    cutout_program: c.bgfx_program_handle_t,
    cutout_sticker_program: c.bgfx_program_handle_t,
    smooth_program: c.bgfx_program_handle_t,
    retouch_program: c.bgfx_program_handle_t,
    matte_refine_program: c.bgfx_program_handle_t,
    stylize_program: c.bgfx_program_handle_t,
    edge_sobel_program: c.bgfx_program_handle_t,
    edge_nms_program: c.bgfx_program_handle_t,
    edge_hyst_program: c.bgfx_program_handle_t,
    warp_program: c.bgfx_program_handle_t,
    trail_program: c.bgfx_program_handle_t,
    ssr_program: c.bgfx_program_handle_t,
    env_program: c.bgfx_program_handle_t,
    envmap_program: c.bgfx_program_handle_t,
    grade_program: c.bgfx_program_handle_t,
    dehaze_program: c.bgfx_program_handle_t,
    dehaze_params_uniform: c.bgfx_uniform_handle_t,
    relight_program: c.bgfx_program_handle_t,
    relight_params_uniform: c.bgfx_uniform_handle_t,
    glare_program: c.bgfx_program_handle_t,
    glare_params_uniform: c.bgfx_uniform_handle_t,
    vignette_program: c.bgfx_program_handle_t,
    vignette_params_uniform: c.bgfx_uniform_handle_t,
    lowlight_program: c.bgfx_program_handle_t,
    lowlight_params_uniform: c.bgfx_uniform_handle_t,
    undistort_program: c.bgfx_program_handle_t,
    undistort_params_uniform: c.bgfx_uniform_handle_t,
    undistort_center_uniform: c.bgfx_uniform_handle_t,
    awb_program: c.bgfx_program_handle_t,
    awb_params_uniform: c.bgfx_uniform_handle_t,
    awb_level_uniform: c.bgfx_uniform_handle_t,
    stabilize_program: c.bgfx_program_handle_t,
    stabilize_params_uniform: c.bgfx_uniform_handle_t,
    zoom_program: c.bgfx_program_handle_t,
    zoom_params_uniform: c.bgfx_uniform_handle_t,
    dereflect_program: c.bgfx_program_handle_t,
    dereflect_params_uniform: c.bgfx_uniform_handle_t,
    harmonize_program: c.bgfx_program_handle_t,
    harmonize_params_uniform: c.bgfx_uniform_handle_t,
    inpaint_program: c.bgfx_program_handle_t,
    inpaint_params_uniform: c.bgfx_uniform_handle_t,
    inpaint_coherence_program: c.bgfx_program_handle_t,
    coherence_uniform: c.bgfx_uniform_handle_t,
    rolling_program: c.bgfx_program_handle_t,
    rolling_params_uniform: c.bgfx_uniform_handle_t,
    parallax_program: c.bgfx_program_handle_t,
    parallax_params_uniform: c.bgfx_uniform_handle_t,
    bloom_extract_program: c.bgfx_program_handle_t,
    bloom_composite_program: c.bgfx_program_handle_t,
    composite_program: c.bgfx_program_handle_t,
    beauty_face_program: c.bgfx_program_handle_t,
    beauty_reshape_program: c.bgfx_program_handle_t,
    reshape_bank_program: c.bgfx_program_handle_t,
    reshape_body_program: c.bgfx_program_handle_t,
    makeup_program: c.bgfx_program_handle_t,
    paint_face_program: c.bgfx_program_handle_t,
    face_swap_program: c.bgfx_program_handle_t,
    lash_program: c.bgfx_program_handle_t,
    model_program: c.bgfx_program_handle_t,
    model_lit_program: c.bgfx_program_handle_t,
    model_instanced_program: c.bgfx_program_handle_t,
    billboard_program: c.bgfx_program_handle_t,
    splat_program: c.bgfx_program_handle_t,
    /// The particle-sim compute program, null on backends it is not built for
    /// (then the CPU sim runs). Its two params uniforms feed each dispatch.
    particle_compute_program: ?c.bgfx_program_handle_t,
    sim_params_uniform: c.bgfx_uniform_handle_t,
    sim_params2_uniform: c.bgfx_uniform_handle_t,
    sim_params3_uniform: c.bgfx_uniform_handle_t,
    sim_params4_uniform: c.bgfx_uniform_handle_t,
    sim_params5_uniform: c.bgfx_uniform_handle_t,
    /// A single-vec4 vertex layout, the stride the particle state buffer binds
    /// to the compute shader as.
    vec4_layout: c.bgfx_vertex_layout_t,
    brush_program: c.bgfx_program_handle_t,
    /// The 176-triangle face-makeup mesh's fixed index buffer -
    /// makeup_mesh.triangle_indices, uploaded once, never changes.
    makeup_index_buffer: c.bgfx_index_buffer_handle_t,
    /// The canonical 898-triangle face mesh: fixed indices and UVs
    /// uploaded once, live landmark positions streamed per draw.
    face_mesh_index_buffer: c.bgfx_index_buffer_handle_t,
    face_mesh_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    face_mesh_position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
    /// The face swap's per-vertex seam feather, one static stream uploaded once
    /// from face_mesh_topology.vertex_feather, 0 on the silhouette to 1 inside.
    face_mesh_feather_buffer: c.bgfx_vertex_buffer_handle_t,
    /// The lash strip: fixed indices and strip UVs uploaded once, live tip
    /// positions rebuilt from the tracked eye landmarks and streamed per draw.
    lash_index_buffer: c.bgfx_index_buffer_handle_t,
    lash_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    lash_position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
    /// The live tracked 111-point contour, stream 0 of a makeup draw -
    /// dynamic (updated every frame submitMakeup runs), unlike every
    /// other buffer here.
    makeup_position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
    /// Stream 1 of a makeup draw: makeup_mesh.canonical_uv scaled into
    /// each effect's own crop of the source image - static, computed
    /// once at init, never changes per-frame the way position does.
    makeup_lipstick_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    makeup_blush_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    tex_color: c.bgfx_uniform_handle_t,
    tex_y: c.bgfx_uniform_handle_t,
    tex_uv: c.bgfx_uniform_handle_t,
    tex_lut: c.bgfx_uniform_handle_t,
    tex_sprite: c.bgfx_uniform_handle_t,
    tex_background: c.bgfx_uniform_handle_t,
    tex_mask: c.bgfx_uniform_handle_t,
    tex_generated: c.bgfx_uniform_handle_t,
    tex_mean: c.bgfx_uniform_handle_t,
    tex_lookup_gray: c.bgfx_uniform_handle_t,
    tex_lookup_origin: c.bgfx_uniform_handle_t,
    tex_lookup_skin: c.bgfx_uniform_handle_t,
    tex_lookup_custom: c.bgfx_uniform_handle_t,
    tex_makeup: c.bgfx_uniform_handle_t,
    tex_depth: c.bgfx_uniform_handle_t,
    blur_step_uniform: c.bgfx_uniform_handle_t,
    dof_uniform: c.bgfx_uniform_handle_t,
    fog_uniform: c.bgfx_uniform_handle_t,
    outline_uniform: c.bgfx_uniform_handle_t,
    tint_uniform: c.bgfx_uniform_handle_t,
    tint_mode_uniform: c.bgfx_uniform_handle_t,
    tint_finish_uniform: c.bgfx_uniform_handle_t,
    occluder_uniform: c.bgfx_uniform_handle_t,
    cutout_uniform: c.bgfx_uniform_handle_t,
    smooth_uniform: c.bgfx_uniform_handle_t,
    retouch_uniform: c.bgfx_uniform_handle_t,
    matte_refine_uniform: c.bgfx_uniform_handle_t,
    stylize_uniform: c.bgfx_uniform_handle_t,
    edge_uniform: c.bgfx_uniform_handle_t,
    edge_texel_uniform: c.bgfx_uniform_handle_t,
    warp_uniform: c.bgfx_uniform_handle_t,
    warp_params_uniform: c.bgfx_uniform_handle_t,
    warp_extra_uniform: c.bgfx_uniform_handle_t,
    warp_points_uniform: c.bgfx_uniform_handle_t,
    warp_fall_uniform: c.bgfx_uniform_handle_t,
    tex_prev: c.bgfx_uniform_handle_t,
    trail_uniform: c.bgfx_uniform_handle_t,
    ssr_uniform: c.bgfx_uniform_handle_t,
    env_params_uniform: c.bgfx_uniform_handle_t,
    env_top_uniform: c.bgfx_uniform_handle_t,
    env_bottom_uniform: c.bgfx_uniform_handle_t,
    env_rot_uniform: c.bgfx_uniform_handle_t,
    grade_params_uniform: c.bgfx_uniform_handle_t,
    composite_params_uniform: c.bgfx_uniform_handle_t,
    composite_chroma_uniform: c.bgfx_uniform_handle_t,
    bloom_params_uniform: c.bgfx_uniform_handle_t,
    tex_bloom: c.bgfx_uniform_handle_t,
    beauty_params_uniform: c.bgfx_uniform_handle_t,
    reshape_params_uniform: c.bgfx_uniform_handle_t,
    makeup_params_uniform: c.bgfx_uniform_handle_t,
    /// The sub-rect a tiled capture is drawing, for the screen-space meshes.
    mesh_tile_uniform: c.bgfx_uniform_handle_t,
    /// paint.face's opacity and blend mode, one vec4 (x opacity, y mode).
    paint_params_uniform: c.bgfx_uniform_handle_t,
    /// face.swap's opacity and seam feather width, one vec4 (x opacity, y width).
    swap_params_uniform: c.bgfx_uniform_handle_t,
    /// mesh.lashes' tint and opacity (u_lashColor), and its strand count and
    /// edge softness (u_lashShape).
    lash_color_uniform: c.bgfx_uniform_handle_t,
    lash_shape_uniform: c.bgfx_uniform_handle_t,
    /// The reshape bank's sixty-six sculpt amounts, four per vec4, and its two
    /// derived anchors (forehead center xy, nose-bridge midpoint zw).
    reshape_bank_uniform: c.bgfx_uniform_handle_t,
    reshape_hubs_uniform: c.bgfx_uniform_handle_t,
    body_params_uniform: c.bgfx_uniform_handle_t,
    body_points_uniform: c.bgfx_uniform_handle_t,
    body_bank_uniform: c.bgfx_uniform_handle_t,
    /// 106 tracked face points, two per vec4 (xy, zw) - matching
    /// fs_beauty_reshape.sc's own u_facePoints packing.
    face_points_uniform: c.bgfx_uniform_handle_t,
    model_color_uniform: c.bgfx_uniform_handle_t,
    light_uniform: c.bgfx_uniform_handle_t,
    material_uniform: c.bgfx_uniform_handle_t,
    particle_cool_uniform: c.bgfx_uniform_handle_t,
    particle_size_uniform: c.bgfx_uniform_handle_t,
    particle_fx_uniform: c.bgfx_uniform_handle_t,
    /// Solid white 1x1: blend.pass's mask input when segmentation is
    /// unavailable. A mask of 1.0 everywhere means "always foreground,"
    /// so binding this reproduces the SPEC's degradation rule exactly -
    /// the pass draws the frame through unblended rather than blocking
    /// the chain or sampling an unbound texture.
    default_mask_texture: c.bgfx_texture_handle_t,
    default_sprite_texture: c.bgfx_texture_handle_t,
    /// The absence-of-signal mask: a named mask channel with no live
    /// data samples zero so the effect draws nothing, never everywhere.
    zero_mask_texture: c.bgfx_texture_handle_t,
    yuv_uniform: c.bgfx_uniform_handle_t,
    upload_cache: ?UploadCache = null,
    rgba_upload_cache: ?RgbaUploadCache = null,
    /// The tile a capture is compositing, or null for a whole frame. When
    /// set, the final full-screen pass samples only this tile's UV span, so
    /// a tile rendered into a small target is byte-identical to that region
    /// of one full-size render - what lets a capture exceed the texture cap.
    tile: ?Tile = null,

    /// Web/wasm renderer choice: WebGPU when this build has it compiled
    /// in, auto-select (OpenGLES/WebGL2) otherwise. Queries bgfx's own
    /// supported-renderers list rather than a build-time flag, since
    /// wasm-emscripten-webgpu and wasm-emscripten link different bgfx
    /// object files.
    fn preferredWebRenderer() c.bgfx_renderer_type_t {
        var supported: [16]c.bgfx_renderer_type_t = undefined;
        const count = c.bgfx_get_supported_renderers(supported.len, &supported);
        for (supported[0..count]) |renderer| {
            if (renderer == c.BGFX_RENDERER_TYPE_WEBGPU) return c.BGFX_RENDERER_TYPE_WEBGPU;
        }
        return c.BGFX_RENDERER_TYPE_COUNT;
    }

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) !Renderer {
        var bgfx_init: c.bgfx_init_t = undefined;
        c.bgfx_init_ctor(&bgfx_init);
        // Metal on apple targets. Android probes for the Vulkan
        // capabilities zero-copy import rests on, brings up the adapter's
        // own device, and takes the GL backend as the declared fallback
        // when either is missing.
        var vk_context: if (is_android) ?android_vk.Context else void = if (is_android) null else {};
        if (is_android) {
            if (@import("vulkan_probe.zig").vulkanReady()) {
                vk_context = android_vk.Context.init() catch null;
            }
        }
        // On any failure below, the adapter-owned device dies only after
        // bgfx (which adopted it) has shut down - errdefers run in
        // reverse declaration order, so this one runs last.
        errdefer if (is_android) {
            if (vk_context) |*ctx| ctx.deinit();
        };
        bgfx_init.type = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
            c.BGFX_RENDERER_TYPE_METAL
        else if (is_android)
            (if (vk_context != null) c.BGFX_RENDERER_TYPE_VULKAN else c.BGFX_RENDERER_TYPE_OPENGLES)
        else
            preferredWebRenderer();
        if (is_android) {
            if (vk_context) |ctx| bgfx_init.platformData.context = ctx.rendererDevice();
        }
        bgfx_init.resolution.width = options.width;
        bgfx_init.resolution.height = options.height;
        bgfx_init.resolution.reset = if (options.vsync) c.BGFX_RESET_VSYNC else c.BGFX_RESET_NONE;
        bgfx_init.platformData.nwh = options.native_window_handle;
        bgfx_init.callback = options.callback orelse goss_bgfx_callbacks();
        // Calling bgfx_render_frame once on this thread before bgfx_init
        // is bgfx's own documented opt-in to single-threaded mode: this
        // thread becomes both the API thread and the render thread,
        // instead of bgfx spawning a separate render thread it would
        // otherwise own. PersistentTexture.rebind's bgfx_override_
        // internal_texture_ptr (zero-copy camera ingress, and the beauty
        // compositing bridge) is documented "must be called only on
        // render thread" - every caller in this codebase runs it from
        // whatever thread submitted the frame, never from a thread bgfx
        // itself spawned, so single-threaded mode is what actually makes
        // that contract hold rather than racing bgfx's internal thread.
        _ = c.bgfx_render_frame(-1);
        if (!c.bgfx_init(&bgfx_init)) {
            // bgfx doesn't retry another backend on its own when a
            // specific type was requested - WebGPU falls back to
            // auto-select here instead of failing outright.
            if (bgfx_init.type == c.BGFX_RENDERER_TYPE_WEBGPU) {
                bgfx_init.type = c.BGFX_RENDERER_TYPE_COUNT;
                _ = c.bgfx_render_frame(-1);
                if (!c.bgfx_init(&bgfx_init)) return error.RendererInit;
            } else {
                return error.RendererInit;
            }
        }
        errdefer c.bgfx_shutdown();

        var layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_POSITION, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_TEXCOORD0, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&layout);

        // A lit model carries its per-vertex normal between position and
        // texcoord so a directional light can shade it; the flat model layout
        // above stays untouched, so a lens with no light renders exactly as before.
        var lit_model_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&lit_model_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&lit_model_layout, c.BGFX_ATTRIB_POSITION, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&lit_model_layout, c.BGFX_ATTRIB_NORMAL, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&lit_model_layout, c.BGFX_ATTRIB_TEXCOORD0, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&lit_model_layout);

        // The fading-sprite mesh carries per vertex, alongside the particle
        // centre: a corner index, remaining-life fraction and spin seed
        // (texcoord0), then the world velocity xy for the stretch (texcoord1).
        var billboard_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&billboard_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&billboard_layout, c.BGFX_ATTRIB_POSITION, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&billboard_layout, c.BGFX_ATTRIB_TEXCOORD0, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&billboard_layout, c.BGFX_ATTRIB_TEXCOORD1, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&billboard_layout, c.BGFX_ATTRIB_COLOR0, 4, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&billboard_layout);

        // A bare vec4 - the particle state buffer's element the compute shader
        // reads and writes.
        var vec4_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&vec4_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&vec4_layout, c.BGFX_ATTRIB_TEXCOORD0, 4, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&vec4_layout);

        const backend = c.bgfx_get_renderer_type();
        const rgba_program, const nv12_program = switch (backend) {
            c.BGFX_RENDERER_TYPE_METAL => .{
                try loadProgram(blobs.vs_preview_metal, blobs.fs_preview_rgba_metal),
                try loadProgram(blobs.vs_preview_metal, blobs.fs_preview_nv12_metal),
            },
            c.BGFX_RENDERER_TYPE_VULKAN => .{
                try loadProgram(blobs.vs_preview_spirv, blobs.fs_preview_rgba_spirv),
                try loadProgram(blobs.vs_preview_spirv, blobs.fs_preview_nv12_spirv),
            },
            c.BGFX_RENDERER_TYPE_OPENGLES => .{
                try loadProgram(blobs.vs_preview_essl, blobs.fs_preview_rgba_essl),
                try loadProgram(blobs.vs_preview_essl, blobs.fs_preview_nv12_essl),
            },
            c.BGFX_RENDERER_TYPE_WEBGPU => .{
                try loadProgram(blobs.vs_preview_wgsl, blobs.fs_preview_rgba_wgsl),
                try loadProgram(blobs.vs_preview_wgsl, blobs.fs_preview_nv12_wgsl),
            },
            else => return error.RendererUnsupported,
        };
        const lut_program = try loadLutProgram();
        const blend_program = try loadBlendProgram();
        const blur_program = try loadBlurProgram();
        const dof_program = try loadDofProgram();
        const fog_program = try loadFogProgram();
        const outline_program = try loadOutlineProgram();
        const tint_program = try loadTintProgram();
        const occluder_program = try loadOccluderProgram();
        const cutout_program = try loadCutoutProgram();
        const cutout_sticker_program = try loadCutoutStickerProgram();
        const smooth_program = try loadSmoothProgram();
        const retouch_program = try loadRetouchProgram();
        const matte_refine_program = try loadMatteRefineProgram();
        const stylize_program = try loadStylizeProgram();
        const edge_sobel_program = try loadEdgeSobelProgram();
        const edge_nms_program = try loadEdgeNmsProgram();
        const edge_hyst_program = try loadEdgeHystProgram();
        const warp_program = try loadWarpProgram();
        const trail_program = try loadTrailProgram();
        const ssr_program = try loadSsrProgram();
        const env_program = try loadEnvProgram();
        const envmap_program = try loadEnvmapProgram();
        const grade_program = try loadGradeProgram();
        const dehaze_program = try loadDehazeProgram();
        const relight_program = try loadRelightProgram();
        const glare_program = try loadGlareProgram();
        const vignette_program = try loadVignetteProgram();
        const lowlight_program = try loadLowLightProgram();
        const undistort_program = try loadUndistortProgram();
        const awb_program = try loadAwbProgram();
        const stabilize_program = try loadStabilizeProgram();
        const zoom_program = try loadZoomProgram();
        const dereflect_program = try loadDereflectProgram();
        const harmonize_program = try loadHarmonizeProgram();
        const inpaint_program = try loadInpaintProgram();
        const inpaint_coherence_program = try loadInpaintCoherenceProgram();
        const rolling_program = try loadRollingProgram();
        const parallax_program = try loadParallaxProgram();
        const bloom_extract_program = try loadBloomExtractProgram();
        const bloom_composite_program = try loadBloomCompositeProgram();
        const composite_program = try loadCompositeProgram();
        const beauty_face_program = try loadBeautyFaceProgram();
        const beauty_reshape_program = try loadBeautyReshapeProgram();
        const reshape_bank_program = try loadReshapeBankProgram();
        const reshape_body_program = try loadReshapeBodyProgram();
        const makeup_program = try loadMakeupProgram();
        const paint_face_program = try loadPaintFaceProgram();
        const face_swap_program = try loadFaceSwapProgram();
        const lash_program = try loadLashProgram();
        const model_program = try loadModelProgram();
        const model_lit_program = try loadModelLitProgram();
        const model_instanced_program = try loadModelInstancedProgram();
        const billboard_program = try loadBillboardProgram();
        const splat_program = try loadSplatProgram();
        const particle_compute_program = loadParticleComputeProgram() catch null;
        const brush_program = try loadBrushProgram();

        // The brush ribbon vertex: a screen-space point and its stroke color.
        var brush_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&brush_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&brush_layout, c.BGFX_ATTRIB_POSITION, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&brush_layout, c.BGFX_ATTRIB_COLOR0, 4, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&brush_layout);

        var makeup_position_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&makeup_position_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&makeup_position_layout, c.BGFX_ATTRIB_POSITION, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&makeup_position_layout);
        var makeup_uv_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&makeup_uv_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&makeup_uv_layout, c.BGFX_ATTRIB_TEXCOORD1, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&makeup_uv_layout);

        const makeup_index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(&makeup_mesh.triangle_indices, @sizeOf(@TypeOf(makeup_mesh.triangle_indices))), 0);
        const makeup_position_buffer = c.bgfx_create_dynamic_vertex_buffer(makeup_mesh.canonical_uv.len / 2, &makeup_position_layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        var lipstick_uv: [makeup_mesh.canonical_uv.len]f32 = undefined;
        makeup_mesh.makeupUv(makeup_mesh.lipstick_bounds, &lipstick_uv);
        const makeup_lipstick_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&lipstick_uv, @sizeOf(@TypeOf(lipstick_uv))), &makeup_uv_layout, 0);
        var blush_uv: [makeup_mesh.canonical_uv.len]f32 = undefined;
        makeup_mesh.makeupUv(makeup_mesh.blush_bounds, &blush_uv);
        const makeup_blush_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&blush_uv, @sizeOf(@TypeOf(blush_uv))), &makeup_uv_layout, 0);

        const face_mesh_index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(&face_mesh_topology.triangle_indices, @sizeOf(@TypeOf(face_mesh_topology.triangle_indices))), 0);
        const face_mesh_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&face_mesh_topology.vertex_uvs, @sizeOf(@TypeOf(face_mesh_topology.vertex_uvs))), &makeup_uv_layout, 0);
        const face_mesh_position_buffer = c.bgfx_create_dynamic_vertex_buffer(face_mesh_topology.vertex_count, &makeup_position_layout, c.BGFX_BUFFER_ALLOW_RESIZE);

        var feather_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&feather_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&feather_layout, c.BGFX_ATTRIB_TEXCOORD2, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&feather_layout);
        var feather_pairs: [face_mesh_topology.vertex_count * 2]f32 = undefined;
        for (face_mesh_topology.vertex_feather, 0..) |weight, at| {
            feather_pairs[at * 2] = weight;
            feather_pairs[at * 2 + 1] = 0.0;
        }
        const face_mesh_feather_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&feather_pairs, @sizeOf(@TypeOf(feather_pairs))), &feather_layout, 0);

        const lash_index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(&lash_mesh.triangle_indices, @sizeOf(@TypeOf(lash_mesh.triangle_indices))), 0);
        const lash_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&lash_mesh.vertex_uvs, @sizeOf(@TypeOf(lash_mesh.vertex_uvs))), &makeup_uv_layout, 0);
        const lash_position_buffer = c.bgfx_create_dynamic_vertex_buffer(lash_mesh.vertex_count, &makeup_position_layout, c.BGFX_BUFFER_ALLOW_RESIZE);

        c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x000000ff, 1.0, 0);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(options.width), @intCast(options.height));

        var zero_copy: ?VkZeroCopy = null;
        if (is_android) {
            if (vk_context) |ctx| {
                if (android_vk.Converter.init(ctx)) |converter| {
                    zero_copy = .{ .converter = converter };
                } else |_| {
                    // The errdefer chain shuts bgfx down before the
                    // device it adopted dies - never inline here.
                    return error.RendererInit;
                }
            }
        }

        return .{
            .gpa = gpa,
            .zero_copy = zero_copy,
            .width = options.width,
            .height = options.height,
            .layout = layout,
            .lit_model_layout = lit_model_layout,
            .billboard_layout = billboard_layout,
            .brush_layout = brush_layout,
            .rgba_program = rgba_program,
            .nv12_program = nv12_program,
            .lut_program = lut_program,
            .blend_program = blend_program,
            .blend_params_uniform = c.bgfx_create_uniform("u_blendParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .blur_program = blur_program,
            .dof_program = dof_program,
            .fog_program = fog_program,
            .outline_program = outline_program,
            .tint_program = tint_program,
            .occluder_program = occluder_program,
            .cutout_program = cutout_program,
            .cutout_sticker_program = cutout_sticker_program,
            .smooth_program = smooth_program,
            .retouch_program = retouch_program,
            .matte_refine_program = matte_refine_program,
            .stylize_program = stylize_program,
            .edge_sobel_program = edge_sobel_program,
            .edge_nms_program = edge_nms_program,
            .edge_hyst_program = edge_hyst_program,
            .warp_program = warp_program,
            .trail_program = trail_program,
            .ssr_program = ssr_program,
            .env_program = env_program,
            .envmap_program = envmap_program,
            .grade_program = grade_program,
            .dehaze_program = dehaze_program,
            .dehaze_params_uniform = c.bgfx_create_uniform("u_dehaze", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .relight_program = relight_program,
            .relight_params_uniform = c.bgfx_create_uniform("u_relight", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .glare_program = glare_program,
            .glare_params_uniform = c.bgfx_create_uniform("u_glare", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .vignette_program = vignette_program,
            .vignette_params_uniform = c.bgfx_create_uniform("u_vignette", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .lowlight_program = lowlight_program,
            .lowlight_params_uniform = c.bgfx_create_uniform("u_lowlight", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .undistort_program = undistort_program,
            .undistort_params_uniform = c.bgfx_create_uniform("u_undistort", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .undistort_center_uniform = c.bgfx_create_uniform("u_undistortC", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .awb_program = awb_program,
            .awb_params_uniform = c.bgfx_create_uniform("u_awb", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .awb_level_uniform = c.bgfx_create_uniform("u_awbLevel", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .stabilize_program = stabilize_program,
            .stabilize_params_uniform = c.bgfx_create_uniform("u_stabilize", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .zoom_program = zoom_program,
            .zoom_params_uniform = c.bgfx_create_uniform("u_zoom", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .dereflect_program = dereflect_program,
            .dereflect_params_uniform = c.bgfx_create_uniform("u_dereflect", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .harmonize_program = harmonize_program,
            .harmonize_params_uniform = c.bgfx_create_uniform("u_harmonize", c.BGFX_UNIFORM_TYPE_VEC4, 4),
            .inpaint_program = inpaint_program,
            .inpaint_params_uniform = c.bgfx_create_uniform("u_inpaint", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .inpaint_coherence_program = inpaint_coherence_program,
            .coherence_uniform = c.bgfx_create_uniform("u_coherence", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .rolling_program = rolling_program,
            .rolling_params_uniform = c.bgfx_create_uniform("u_rolling", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .parallax_program = parallax_program,
            .parallax_params_uniform = c.bgfx_create_uniform("u_parallax", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .bloom_extract_program = bloom_extract_program,
            .bloom_composite_program = bloom_composite_program,
            .composite_program = composite_program,
            .beauty_face_program = beauty_face_program,
            .beauty_reshape_program = beauty_reshape_program,
            .reshape_bank_program = reshape_bank_program,
            .reshape_body_program = reshape_body_program,
            .makeup_program = makeup_program,
            .paint_face_program = paint_face_program,
            .face_swap_program = face_swap_program,
            .lash_program = lash_program,
            .model_program = model_program,
            .model_lit_program = model_lit_program,
            .model_instanced_program = model_instanced_program,
            .billboard_program = billboard_program,
            .splat_program = splat_program,
            .particle_compute_program = particle_compute_program,
            .sim_params_uniform = c.bgfx_create_uniform("u_simParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .sim_params2_uniform = c.bgfx_create_uniform("u_simParams2", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .sim_params3_uniform = c.bgfx_create_uniform("u_simParams3", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .sim_params4_uniform = c.bgfx_create_uniform("u_simParams4", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .sim_params5_uniform = c.bgfx_create_uniform("u_simParams5", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .vec4_layout = vec4_layout,
            .brush_program = brush_program,
            .makeup_index_buffer = makeup_index_buffer,
            .face_mesh_index_buffer = face_mesh_index_buffer,
            .face_mesh_uv_buffer = face_mesh_uv_buffer,
            .face_mesh_position_buffer = face_mesh_position_buffer,
            .face_mesh_feather_buffer = face_mesh_feather_buffer,
            .lash_index_buffer = lash_index_buffer,
            .lash_uv_buffer = lash_uv_buffer,
            .lash_position_buffer = lash_position_buffer,
            .makeup_position_buffer = makeup_position_buffer,
            .makeup_lipstick_uv_buffer = makeup_lipstick_uv_buffer,
            .makeup_blush_uv_buffer = makeup_blush_uv_buffer,
            .tex_color = c.bgfx_create_uniform("s_texColor", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_y = c.bgfx_create_uniform("s_texY", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_uv = c.bgfx_create_uniform("s_texUV", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lut = c.bgfx_create_uniform("s_texLut", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_sprite = c.bgfx_create_uniform("s_texSprite", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_background = c.bgfx_create_uniform("s_texBackground", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_mask = c.bgfx_create_uniform("s_texMask", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_generated = c.bgfx_create_uniform("s_generated", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_mean = c.bgfx_create_uniform("s_texMean", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_gray = c.bgfx_create_uniform("s_texLookupGray", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_origin = c.bgfx_create_uniform("s_texLookupOrigin", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_skin = c.bgfx_create_uniform("s_texLookupSkin", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_custom = c.bgfx_create_uniform("s_texLookupCustom", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_makeup = c.bgfx_create_uniform("s_texMakeup", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_depth = c.bgfx_create_uniform("s_texDepth", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .blur_step_uniform = c.bgfx_create_uniform("u_blurStep", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .dof_uniform = c.bgfx_create_uniform("u_dof", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .fog_uniform = c.bgfx_create_uniform("u_fog", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .outline_uniform = c.bgfx_create_uniform("u_outline", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .tint_uniform = c.bgfx_create_uniform("u_tint", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .tint_mode_uniform = c.bgfx_create_uniform("u_tintMode", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .tint_finish_uniform = c.bgfx_create_uniform("u_tintFinish", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .occluder_uniform = c.bgfx_create_uniform("u_occluder", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .cutout_uniform = c.bgfx_create_uniform("u_cutout", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .smooth_uniform = c.bgfx_create_uniform("u_smooth", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .retouch_uniform = c.bgfx_create_uniform("u_retouch", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .matte_refine_uniform = c.bgfx_create_uniform("u_matteRefine", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .stylize_uniform = c.bgfx_create_uniform("u_stylize", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .edge_uniform = c.bgfx_create_uniform("u_edge", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .edge_texel_uniform = c.bgfx_create_uniform("u_edgeTexel", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .warp_uniform = c.bgfx_create_uniform("u_warp", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .warp_params_uniform = c.bgfx_create_uniform("u_warpParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            // The liquify arrays hold up to eight push points; the count must
            // match warp_point_max in the lens core and WARP_POINTS in the shader.
            .warp_extra_uniform = c.bgfx_create_uniform("u_warpExtra", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .warp_points_uniform = c.bgfx_create_uniform("u_warpPoints", c.BGFX_UNIFORM_TYPE_VEC4, 8),
            .warp_fall_uniform = c.bgfx_create_uniform("u_warpFall", c.BGFX_UNIFORM_TYPE_VEC4, 8),
            .tex_prev = c.bgfx_create_uniform("s_texPrev", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .trail_uniform = c.bgfx_create_uniform("u_trail", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .ssr_uniform = c.bgfx_create_uniform("u_ssr", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .env_params_uniform = c.bgfx_create_uniform("u_envParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .env_top_uniform = c.bgfx_create_uniform("u_envTop", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .env_bottom_uniform = c.bgfx_create_uniform("u_envBottom", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .env_rot_uniform = c.bgfx_create_uniform("u_envRot", c.BGFX_UNIFORM_TYPE_VEC4, 3),
            .grade_params_uniform = c.bgfx_create_uniform("u_grade", c.BGFX_UNIFORM_TYPE_VEC4, 3),
            .composite_params_uniform = c.bgfx_create_uniform("u_composite", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .composite_chroma_uniform = c.bgfx_create_uniform("u_chroma", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .bloom_params_uniform = c.bgfx_create_uniform("u_bloom", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .tex_bloom = c.bgfx_create_uniform("s_texBloom", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .beauty_params_uniform = c.bgfx_create_uniform("u_beautyParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .reshape_params_uniform = c.bgfx_create_uniform("u_reshapeParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .reshape_bank_uniform = c.bgfx_create_uniform("u_reshapeBank", c.BGFX_UNIFORM_TYPE_VEC4, face_reshape_bank_vec4_count),
            .reshape_hubs_uniform = c.bgfx_create_uniform("u_reshapeHubs", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .body_params_uniform = c.bgfx_create_uniform("u_bodyParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .body_points_uniform = c.bgfx_create_uniform("u_bodyPoints", c.BGFX_UNIFORM_TYPE_VEC4, body_reshape_points_vec4_count),
            .body_bank_uniform = c.bgfx_create_uniform("u_bodyBank", c.BGFX_UNIFORM_TYPE_VEC4, body_reshape_bank_vec4_count),
            .makeup_params_uniform = c.bgfx_create_uniform("u_makeupParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .mesh_tile_uniform = c.bgfx_create_uniform("u_meshTile", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .paint_params_uniform = c.bgfx_create_uniform("u_paintParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .swap_params_uniform = c.bgfx_create_uniform("u_swapParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .lash_color_uniform = c.bgfx_create_uniform("u_lashColor", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .lash_shape_uniform = c.bgfx_create_uniform("u_lashShape", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .face_points_uniform = c.bgfx_create_uniform("u_facePoints", c.BGFX_UNIFORM_TYPE_VEC4, face_point_vec4_count),
            .model_color_uniform = c.bgfx_create_uniform("u_modelColor", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .light_uniform = c.bgfx_create_uniform("u_light", c.BGFX_UNIFORM_TYPE_VEC4, 4),
            .material_uniform = c.bgfx_create_uniform("u_material", c.BGFX_UNIFORM_TYPE_VEC4, 2),
            .particle_cool_uniform = c.bgfx_create_uniform("u_particleCool", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .particle_size_uniform = c.bgfx_create_uniform("u_particleSize", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .particle_fx_uniform = c.bgfx_create_uniform("u_particleFx", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .default_mask_texture = createMaskTexture(1, 1, &[_]u8{255}),
            .zero_mask_texture = createMaskTexture(1, 1, &[_]u8{0}),
            .default_sprite_texture = createStaticTexture(1, 1, &[_]u8{ 255, 255, 255, 255 }),
            .yuv_uniform = c.bgfx_create_uniform("u_yuvTransform", c.BGFX_UNIFORM_TYPE_MAT4, 1),
        };
    }

    fn loadProgram(vs_blob: []const u8, fs_blob: []const u8) !c.bgfx_program_handle_t {
        const vsh = c.bgfx_create_shader(c.bgfx_copy(vs_blob.ptr, @intCast(vs_blob.len)));
        const fsh = c.bgfx_create_shader(c.bgfx_copy(fs_blob.ptr, @intCast(fs_blob.len)));
        const program = c.bgfx_create_program(vsh, fsh, true);
        if (program.idx == invalid_handle) return error.ProgramCreate;
        return program;
    }

    /// The compiled bytecode file suffix matching bgfx's currently
    /// active backend - the one source of truth for which
    /// packaged shader variant a lens shader pass needs, shared between
    /// loadLensProgram below and whatever reads the bytes off disk.
    pub fn currentShaderProfileTag() ![]const u8 {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => "metal",
            c.BGFX_RENDERER_TYPE_VULKAN => "spirv",
            c.BGFX_RENDERER_TYPE_OPENGLES => "essl",
            c.BGFX_RENDERER_TYPE_WEBGPU => "wgsl",
            else => error.RendererUnsupported,
        };
    }

    /// Pairs a lens's compiled fragment shader with the one fixed vertex
    /// shader every lens shader pass shares (lenses/shaders/vs_lens_pass.sc),
    /// picking the vertex blob matching the same backend fs_bytes was
    /// compiled for - the caller is responsible for having read the
    /// right profile's .bin file (currentShaderProfileTag tells it which).
    pub fn loadLensProgram(fs_bytes: []const u8) !c.bgfx_program_handle_t {
        const vs_blob = switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => blobs.vs_lens_pass_metal,
            c.BGFX_RENDERER_TYPE_VULKAN => blobs.vs_lens_pass_spirv,
            c.BGFX_RENDERER_TYPE_OPENGLES => blobs.vs_lens_pass_essl,
            c.BGFX_RENDERER_TYPE_WEBGPU => blobs.vs_lens_pass_wgsl,
            else => return error.RendererUnsupported,
        };
        return loadProgram(vs_blob, fs_bytes);
    }

    /// The one fixed lut.pass program every lens shares - kit-authored,
    /// so unlike loadLensProgram this takes no bytes; there is nothing
    /// per-lens to compile for this node type. A real Renderer instance
    /// builds this once at init and keeps it in lut_program; this
    /// static form exists so a caller without an instance (a proof, a
    /// test) can still get the exact same program.
    pub fn loadLutProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_lut_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_lut_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_lut_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_lut_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed blend.pass program every lens shares - kit-authored
    /// like lut_program, same reasoning.
    pub fn loadBlendProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_blend_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_blend_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_blend_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_blend_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// beauty.face's smooth effect blur input - one program, run twice
    /// (horizontal then vertical) with a different u_blurStep each time.
    pub fn loadBlurProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_blur_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_blur_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_blur_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_blur_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// dof.pass's own fixed depth-of-field program: the frame on unit 0 and
    /// the depth texture on unit 1, mixed sharp-to-blurred by depth.
    pub fn loadDofProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_dof_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_dof_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_dof_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_dof_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// fog.pass's own fixed depth-fog program: the frame on unit 0 and the
    /// depth on unit 1, faded toward the fog color by depth.
    pub fn loadFogProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_fog_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_fog_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_fog_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_fog_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// outline.pass's own fixed depth-edge program: the frame on unit 0 and
    /// the depth on unit 1, outlined where depth jumps between neighbors.
    pub fn loadOutlineProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_outline_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_outline_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_outline_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_outline_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadTintProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_tint_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_tint_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_tint_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_tint_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// occluder.pass's own fixed head-occluder program: the composited frame
    /// on unit 0, the preserved camera frame on unit 1, and the head matte on
    /// unit 2, revealing the head over content drawn behind it.
    pub fn loadOccluderProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_occluder_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_occluder_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_occluder_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_occluder_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// cutout.pass's own fixed program: the frame on unit 0 and the face matte
    /// on unit 1, keeping the frame where the matte is set and replacing the
    /// rest with a flat color, so the face reads on a plain background.
    pub fn loadCutoutProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_cutout_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_cutout_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_cutout_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_cutout_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadCutoutStickerProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_cutout_sticker_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_cutout_sticker_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_cutout_sticker_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_cutout_sticker_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadSmoothProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_smooth_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_smooth_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_smooth_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_smooth_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// retouch.pass's own fixed program: the frame on unit 0 and its mask on
    /// unit 1, running one of the selective skin filters its mode uniform picks.
    pub fn loadRetouchProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_retouch_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_retouch_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_retouch_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_retouch_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// matte.refine's own fixed guided-filter program: the frame on unit 0 as
    /// the edge guide and the matte on unit 1, refined into a crisper matte.
    pub fn loadMatteRefineProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_matte_refine_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_matte_refine_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_matte_refine_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_matte_refine_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// trail.pass's own fixed motion-trail program: the current frame on
    /// unit 0 and the previous frame on unit 1, blended into an echo.
    pub fn loadTrailProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_trail_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_trail_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_trail_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_trail_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// ssr.pass's own fixed reflection program: the frame on unit 0 and the
    /// submitted depth on unit 1, mirroring the scene into a reflective floor.
    pub fn loadSsrProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_ssr_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_ssr_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_ssr_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_ssr_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// env.pass's own fixed sky program: the frame on unit 0 and the mask on
    /// unit 1, drawing a procedural sky dome behind the segmented foreground.
    pub fn loadEnvProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_env_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_env_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_env_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_env_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// env.pass's image variant: samples an equirect environment on unit 1 by
    /// the pose-rotated view ray, compositing it behind the foreground.
    pub fn loadEnvmapProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_envmap_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_envmap_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_envmap_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_envmap_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// grade.pass's own fixed parametric-grade program every lens shares -
    /// kit-authored like lut_program, same reasoning.
    pub fn loadGradeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_grade_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_grade_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_grade_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_grade_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// dehaze.pass's own fixed program: the single-pass dark-channel dehaze,
    /// shared by every dehaze.pass node like grade_program.
    pub fn loadDehazeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_dehaze_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_dehaze_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_dehaze_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_dehaze_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// relight.pass's own fixed program: the parametric directional relight,
    /// shared by every relight.pass node like grade_program.
    pub fn loadRelightProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_relight_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_relight_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_relight_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_relight_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// glare.pass's own fixed program: the specular-highlight rolloff, shared by
    /// every glare.pass node like grade_program.
    pub fn loadGlareProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_glare_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_glare_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_glare_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_glare_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// vignette.pass's own fixed program: the radial luma-gain, shared by every
    /// vignette.pass node like grade_program.
    pub fn loadVignetteProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_vignette_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_vignette_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_vignette_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_vignette_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// lowlight.pass's own fixed program: the shadow-lift + denoise, shared by
    /// every lowlight.pass node like grade_program.
    pub fn loadLowLightProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_lowlight_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_lowlight_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_lowlight_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_lowlight_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// undistort.pass's own fixed program: the inverse radial remap, shared by
    /// every undistort.pass node like grade_program.
    pub fn loadUndistortProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_undistort_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_undistort_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_undistort_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_undistort_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// awb.pass's own fixed program: the gray-world white balance and auto-levels,
    /// shared by every awb.pass node like grade_program.
    pub fn loadAwbProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_awb_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_awb_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_awb_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_awb_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// stabilize.pass's own fixed program: the crop-and-shift stabilization,
    /// shared by every stabilize.pass node like grade_program.
    pub fn loadStabilizeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_stabilize_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_stabilize_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_stabilize_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_stabilize_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// zoom.pass's own fixed program: the digital region magnify, shared by every
    /// zoom.pass node like grade_program.
    pub fn loadZoomProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_zoom_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_zoom_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_zoom_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_zoom_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// dereflect.pass's own fixed program: the localized specular attenuation,
    /// shared by every dereflect.pass node like grade_program.
    pub fn loadDereflectProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_dereflect_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_dereflect_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_dereflect_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_dereflect_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// harmonize.pass's own fixed program: the statistical color transfer, shared
    /// by every harmonize.pass node like grade_program.
    pub fn loadHarmonizeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_harmonize_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_harmonize_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_harmonize_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_harmonize_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadInpaintProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_inpaint_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_inpaint_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_inpaint_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_inpaint_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadInpaintCoherenceProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_inpaint_coherence_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_inpaint_coherence_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_inpaint_coherence_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_inpaint_coherence_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadRollingProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_rolling_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_rolling_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_rolling_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_rolling_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadParallaxProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_parallax_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_parallax_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_parallax_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_parallax_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// stylize.pass's own fixed program: one artistic filter that branches on
    /// its mode uniform, shared by every stylize.pass node like grade_program.
    pub fn loadStylizeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_stylize_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_stylize_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_stylize_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_stylize_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// edge.pass's grayscale-and-sobel program, shared by the single-pass
    /// sobel node and canny's directional-sobel stage - its mode uniform picks
    /// magnitude-only or magnitude-plus-direction output.
    pub fn loadEdgeSobelProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_edge_sobel_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_edge_sobel_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_edge_sobel_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_edge_sobel_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// canny's non-maximum suppression program: thins the sobel magnitude to
    /// its local maxima along the gradient, shared by every edge.pass node.
    pub fn loadEdgeNmsProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_edge_nms_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_edge_nms_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_edge_nms_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_edge_nms_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// canny's weak-pixel hysteresis program: keeps a suppressed pixel only
    /// where enough of its neighbours survived, shared by every edge.pass node.
    pub fn loadEdgeHystProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_edge_hyst_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_edge_hyst_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_edge_hyst_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_edge_hyst_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// warp.pass's own fixed program: one geometric distortion that branches
    /// on its mode uniform, shared by every warp.pass node like stylize_program.
    pub fn loadWarpProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_warp_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_warp_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_warp_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_warp_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// layout.composite's per-source blend program, shared by every source: the
    /// shared vertex contract plus the composite fragment shader.
    pub fn loadCompositeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_composite_source_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_composite_source_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_composite_source_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_composite_source_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// bloom.pass's bright-extract program every lens shares - kit-authored
    /// like lut_program, same reasoning.
    pub fn loadBloomExtractProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_bloom_extract_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_bloom_extract_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_bloom_extract_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_bloom_extract_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// bloom.pass's additive-composite program every lens shares -
    /// kit-authored like lut_program, same reasoning.
    pub fn loadBloomCompositeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_bloom_composite_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_bloom_composite_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_bloom_composite_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_bloom_composite_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.face program every lens shares - kit-authored
    /// like lut_program, same reasoning.
    pub fn loadBeautyFaceProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_beauty_face_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_beauty_face_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_beauty_face_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_beauty_face_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.reshape program every lens shares -
    /// kit-authored like lut_program, same reasoning.
    pub fn loadBeautyReshapeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_beauty_reshape_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_beauty_reshape_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_beauty_reshape_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_beauty_reshape_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed reshape.bank program every lens shares - the sixty-six
    /// per-region face sculpt over the shared vs_lens_pass quad, kit-authored
    /// like loadBeautyReshapeProgram above.
    pub fn loadReshapeBankProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_reshape_bank_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_reshape_bank_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_reshape_bank_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_reshape_bank_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadReshapeBodyProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_reshape_body_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_reshape_body_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_reshape_body_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_reshape_body_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.lipstick/beauty.blusher program every lens
    /// shares - its own vertex stage (vs_makeup, not vs_lens_pass; the
    /// mesh needs two vertex attributes, not a full-screen quad).
    pub fn loadMakeupProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_makeup_metal, blobs.fs_makeup_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_makeup_spirv, blobs.fs_makeup_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_makeup_essl, blobs.fs_makeup_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_makeup_wgsl, blobs.fs_makeup_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// paint.face's program: the makeup mesh vertex stage paired with the
    /// face-material fragment shader, so a lens texture warps over the tracked
    /// face and blends onto the skin through a mask channel.
    pub fn loadPaintFaceProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_makeup_metal, blobs.fs_paint_face_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_makeup_spirv, blobs.fs_paint_face_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_makeup_essl, blobs.fs_paint_face_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_makeup_wgsl, blobs.fs_paint_face_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// face.swap's program: its own mesh vertex stage carries the per-vertex
    /// seam feather beside the position and UV, and the fragment stage warps
    /// the donor face onto the tracked mesh and feathers it into the skin.
    pub fn loadFaceSwapProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_face_swap_metal, blobs.fs_face_swap_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_face_swap_spirv, blobs.fs_face_swap_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_face_swap_essl, blobs.fs_face_swap_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_face_swap_wgsl, blobs.fs_face_swap_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// mesh.lashes' program: the makeup mesh vertex stage paired with the
    /// lash fragment shader, so the strip's live positions draw as strands
    /// rising off the lid in the node's tint.
    pub fn loadLashProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_makeup_metal, blobs.fs_lashes_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_makeup_spirv, blobs.fs_lashes_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_makeup_essl, blobs.fs_lashes_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_makeup_wgsl, blobs.fs_lashes_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed model.gltf program every lens shares - reuses
    /// vs_lens_pass.sc (the mesh's vertex data is padded with a dummy
    /// texcoord so it fits the same interleaved POSITION+TEXCOORD0
    /// layout every full-screen-quad pass already uses), pairs it with
    /// its own fragment shader that outputs one flat uniform-driven
    /// color rather than sampling a texture.
    pub fn loadModelProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_model_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_model_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_model_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_model_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The lit model program: the normal-carrying vertex stage and the
    /// directional-light fragment stage, shading a model.gltf when its lens
    /// declares a light. Same renderer split as the flat model program.
    pub fn loadModelLitProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_model_lit_metal, blobs.fs_model_lit_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_model_lit_spirv, blobs.fs_model_lit_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_model_lit_essl, blobs.fs_model_lit_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_model_lit_wgsl, blobs.fs_model_lit_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The model program's instanced twin: the same fragment stage over the
    /// instanced vertex stage, so a cloud of the same mesh draws in one call.
    pub fn loadModelInstancedProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_instanced_metal, blobs.fs_model_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_instanced_spirv, blobs.fs_model_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_instanced_essl, blobs.fs_model_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_instanced_wgsl, blobs.fs_model_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The fading-sprite program every lens shares - its own vertex stage
    /// expands each particle centre into a camera-facing quad, kit-authored.
    pub fn loadBillboardProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_billboard_metal, blobs.fs_billboard_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_billboard_spirv, blobs.fs_billboard_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_billboard_essl, blobs.fs_billboard_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_billboard_wgsl, blobs.fs_billboard_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn loadSplatProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_splat_metal, blobs.fs_splat_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_splat_spirv, blobs.fs_splat_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_splat_essl, blobs.fs_splat_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_splat_wgsl, blobs.fs_splat_wgsl),
            else => error.RendererUnsupported,
        };
    }

    fn loadCompute(cs_blob: []const u8) !c.bgfx_program_handle_t {
        const csh = c.bgfx_create_shader(c.bgfx_copy(cs_blob.ptr, @intCast(cs_blob.len)));
        const program = c.bgfx_create_compute_program(csh, true);
        if (program.idx == invalid_handle) return error.ProgramCreate;
        return program;
    }

    /// The particle-sim compute program, built only for Metal and Vulkan; the
    /// caller falls back to the CPU sim on the other backends.
    pub fn loadParticleComputeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadCompute(blobs.cs_particle_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadCompute(blobs.cs_particle_spirv),
            else => error.RendererUnsupported,
        };
    }

    /// draw.board's flat per-vertex color program: the brush ribbon in screen
    /// space, kit-authored like the billboard program above.
    pub fn loadBrushProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_brush_metal, blobs.fs_brush_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_brush_spirv, blobs.fs_brush_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_brush_essl, blobs.fs_brush_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_brush_wgsl, blobs.fs_brush_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn destroyProgram(program: c.bgfx_program_handle_t) void {
        c.bgfx_destroy_program(program);
    }

    pub fn deinit(r: *Renderer) void {
        // converter.deinit() wipes the converter to undefined, so the
        // Vulkan context is copied out first and destroyed after bgfx
        // shutdown from the saved copy, never read back from that memory.
        var saved_vk_ctx: if (is_android) ?android_vk.Context else void = if (is_android) null else {};
        if (is_android) {
            if (r.zero_copy) |*zc| {
                for (zc.textures) |texture| {
                    if (texture.idx != invalid_handle) c.bgfx_destroy_texture(texture);
                }
                zc.beauty_render_target.deinit(zc.converter.ctx.device);
                zc.beauty_import.deinit(zc.converter.ctx.device);
                saved_vk_ctx = zc.converter.ctx;
                zc.converter.deinit();
            }
        }
        if (r.upload_cache) |cache| {
            c.bgfx_destroy_texture(cache.y);
            c.bgfx_destroy_texture(cache.uv);
        }
        if (r.rgba_upload_cache) |cache| {
            c.bgfx_destroy_texture(cache.texture);
        }
        c.bgfx_destroy_texture(r.default_mask_texture);
        c.bgfx_destroy_texture(r.zero_mask_texture);
        c.bgfx_destroy_texture(r.default_sprite_texture);
        c.bgfx_destroy_uniform(r.tex_color);
        c.bgfx_destroy_uniform(r.tex_y);
        c.bgfx_destroy_uniform(r.tex_uv);
        c.bgfx_destroy_uniform(r.tex_lut);
        c.bgfx_destroy_uniform(r.tex_sprite);
        c.bgfx_destroy_uniform(r.tex_background);
        c.bgfx_destroy_uniform(r.tex_mask);
        c.bgfx_destroy_uniform(r.tex_generated);
        c.bgfx_destroy_uniform(r.tex_mean);
        c.bgfx_destroy_uniform(r.tex_lookup_gray);
        c.bgfx_destroy_uniform(r.tex_lookup_origin);
        c.bgfx_destroy_uniform(r.tex_lookup_skin);
        c.bgfx_destroy_uniform(r.tex_lookup_custom);
        c.bgfx_destroy_uniform(r.tex_makeup);
        c.bgfx_destroy_uniform(r.tex_depth);
        c.bgfx_destroy_uniform(r.blur_step_uniform);
        c.bgfx_destroy_uniform(r.dof_uniform);
        c.bgfx_destroy_uniform(r.fog_uniform);
        c.bgfx_destroy_uniform(r.outline_uniform);
        c.bgfx_destroy_uniform(r.tint_mode_uniform);
        c.bgfx_destroy_uniform(r.tint_finish_uniform);
        c.bgfx_destroy_uniform(r.occluder_uniform);
        c.bgfx_destroy_uniform(r.cutout_uniform);
        c.bgfx_destroy_uniform(r.matte_refine_uniform);
        c.bgfx_destroy_uniform(r.stylize_uniform);
        c.bgfx_destroy_uniform(r.edge_uniform);
        c.bgfx_destroy_uniform(r.edge_texel_uniform);
        c.bgfx_destroy_uniform(r.warp_uniform);
        c.bgfx_destroy_uniform(r.warp_params_uniform);
        c.bgfx_destroy_uniform(r.warp_extra_uniform);
        c.bgfx_destroy_uniform(r.warp_points_uniform);
        c.bgfx_destroy_uniform(r.warp_fall_uniform);
        c.bgfx_destroy_uniform(r.tex_prev);
        c.bgfx_destroy_uniform(r.trail_uniform);
        c.bgfx_destroy_uniform(r.ssr_uniform);
        c.bgfx_destroy_uniform(r.env_params_uniform);
        c.bgfx_destroy_uniform(r.env_top_uniform);
        c.bgfx_destroy_uniform(r.env_bottom_uniform);
        c.bgfx_destroy_uniform(r.env_rot_uniform);
        c.bgfx_destroy_uniform(r.grade_params_uniform);
        c.bgfx_destroy_uniform(r.composite_params_uniform);
        c.bgfx_destroy_uniform(r.composite_chroma_uniform);
        c.bgfx_destroy_uniform(r.bloom_params_uniform);
        c.bgfx_destroy_uniform(r.tex_bloom);
        c.bgfx_destroy_uniform(r.beauty_params_uniform);
        c.bgfx_destroy_uniform(r.reshape_params_uniform);
        c.bgfx_destroy_uniform(r.body_params_uniform);
        c.bgfx_destroy_uniform(r.body_points_uniform);
        c.bgfx_destroy_uniform(r.body_bank_uniform);
        c.bgfx_destroy_uniform(r.reshape_bank_uniform);
        c.bgfx_destroy_uniform(r.reshape_hubs_uniform);
        c.bgfx_destroy_uniform(r.makeup_params_uniform);
        c.bgfx_destroy_uniform(r.mesh_tile_uniform);
        c.bgfx_destroy_uniform(r.paint_params_uniform);
        c.bgfx_destroy_uniform(r.swap_params_uniform);
        c.bgfx_destroy_uniform(r.lash_color_uniform);
        c.bgfx_destroy_uniform(r.lash_shape_uniform);
        c.bgfx_destroy_uniform(r.face_points_uniform);
        c.bgfx_destroy_uniform(r.model_color_uniform);
        c.bgfx_destroy_uniform(r.light_uniform);
        c.bgfx_destroy_uniform(r.material_uniform);
        c.bgfx_destroy_uniform(r.particle_cool_uniform);
        c.bgfx_destroy_uniform(r.particle_size_uniform);
        c.bgfx_destroy_uniform(r.particle_fx_uniform);
        c.bgfx_destroy_uniform(r.yuv_uniform);
        c.bgfx_destroy_uniform(r.tint_uniform);
        c.bgfx_destroy_uniform(r.smooth_uniform);
        c.bgfx_destroy_uniform(r.retouch_uniform);
        c.bgfx_destroy_uniform(r.sim_params_uniform);
        c.bgfx_destroy_uniform(r.sim_params2_uniform);
        c.bgfx_destroy_uniform(r.sim_params3_uniform);
        c.bgfx_destroy_uniform(r.sim_params4_uniform);
        c.bgfx_destroy_uniform(r.sim_params5_uniform);
        c.bgfx_destroy_program(r.brush_program);
        if (r.particle_compute_program) |compute_program| c.bgfx_destroy_program(compute_program);
        c.bgfx_destroy_program(r.rgba_program);
        c.bgfx_destroy_program(r.nv12_program);
        c.bgfx_destroy_program(r.lut_program);
        c.bgfx_destroy_program(r.blend_program);
        c.bgfx_destroy_uniform(r.blend_params_uniform);
        c.bgfx_destroy_program(r.blur_program);
        c.bgfx_destroy_program(r.dof_program);
        c.bgfx_destroy_program(r.fog_program);
        c.bgfx_destroy_program(r.outline_program);
        c.bgfx_destroy_program(r.tint_program);
        c.bgfx_destroy_program(r.occluder_program);
        c.bgfx_destroy_program(r.cutout_program);
        c.bgfx_destroy_program(r.cutout_sticker_program);
        c.bgfx_destroy_program(r.smooth_program);
        c.bgfx_destroy_program(r.retouch_program);
        c.bgfx_destroy_program(r.matte_refine_program);
        c.bgfx_destroy_program(r.stylize_program);
        c.bgfx_destroy_program(r.edge_sobel_program);
        c.bgfx_destroy_program(r.edge_nms_program);
        c.bgfx_destroy_program(r.edge_hyst_program);
        c.bgfx_destroy_program(r.warp_program);
        c.bgfx_destroy_program(r.trail_program);
        c.bgfx_destroy_program(r.ssr_program);
        c.bgfx_destroy_program(r.env_program);
        c.bgfx_destroy_program(r.envmap_program);
        c.bgfx_destroy_program(r.grade_program);
        c.bgfx_destroy_program(r.dehaze_program);
        c.bgfx_destroy_uniform(r.dehaze_params_uniform);
        c.bgfx_destroy_program(r.relight_program);
        c.bgfx_destroy_uniform(r.relight_params_uniform);
        c.bgfx_destroy_program(r.glare_program);
        c.bgfx_destroy_uniform(r.glare_params_uniform);
        c.bgfx_destroy_program(r.vignette_program);
        c.bgfx_destroy_uniform(r.vignette_params_uniform);
        c.bgfx_destroy_program(r.lowlight_program);
        c.bgfx_destroy_uniform(r.lowlight_params_uniform);
        c.bgfx_destroy_program(r.undistort_program);
        c.bgfx_destroy_uniform(r.undistort_params_uniform);
        c.bgfx_destroy_uniform(r.undistort_center_uniform);
        c.bgfx_destroy_program(r.awb_program);
        c.bgfx_destroy_uniform(r.awb_params_uniform);
        c.bgfx_destroy_uniform(r.awb_level_uniform);
        c.bgfx_destroy_program(r.stabilize_program);
        c.bgfx_destroy_uniform(r.stabilize_params_uniform);
        c.bgfx_destroy_program(r.zoom_program);
        c.bgfx_destroy_uniform(r.zoom_params_uniform);
        c.bgfx_destroy_program(r.dereflect_program);
        c.bgfx_destroy_uniform(r.dereflect_params_uniform);
        c.bgfx_destroy_program(r.harmonize_program);
        c.bgfx_destroy_uniform(r.harmonize_params_uniform);
        c.bgfx_destroy_program(r.inpaint_program);
        c.bgfx_destroy_uniform(r.inpaint_params_uniform);
        c.bgfx_destroy_program(r.inpaint_coherence_program);
        c.bgfx_destroy_uniform(r.coherence_uniform);
        c.bgfx_destroy_program(r.rolling_program);
        c.bgfx_destroy_uniform(r.rolling_params_uniform);
        c.bgfx_destroy_program(r.parallax_program);
        c.bgfx_destroy_uniform(r.parallax_params_uniform);
        c.bgfx_destroy_program(r.composite_program);
        c.bgfx_destroy_program(r.bloom_extract_program);
        c.bgfx_destroy_program(r.bloom_composite_program);
        c.bgfx_destroy_program(r.beauty_face_program);
        c.bgfx_destroy_program(r.beauty_reshape_program);
        c.bgfx_destroy_program(r.reshape_bank_program);
        c.bgfx_destroy_program(r.reshape_body_program);
        c.bgfx_destroy_program(r.makeup_program);
        c.bgfx_destroy_program(r.paint_face_program);
        c.bgfx_destroy_program(r.face_swap_program);
        c.bgfx_destroy_program(r.lash_program);
        c.bgfx_destroy_program(r.model_program);
        c.bgfx_destroy_program(r.model_lit_program);
        c.bgfx_destroy_program(r.model_instanced_program);
        c.bgfx_destroy_program(r.billboard_program);
        c.bgfx_destroy_program(r.splat_program);
        c.bgfx_destroy_index_buffer(r.makeup_index_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(r.makeup_position_buffer);
        c.bgfx_destroy_vertex_buffer(r.makeup_lipstick_uv_buffer);
        c.bgfx_destroy_vertex_buffer(r.makeup_blush_uv_buffer);
        c.bgfx_destroy_index_buffer(r.face_mesh_index_buffer);
        c.bgfx_destroy_vertex_buffer(r.face_mesh_uv_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(r.face_mesh_position_buffer);
        c.bgfx_destroy_vertex_buffer(r.face_mesh_feather_buffer);
        c.bgfx_destroy_index_buffer(r.lash_index_buffer);
        c.bgfx_destroy_vertex_buffer(r.lash_uv_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(r.lash_position_buffer);
        c.bgfx_shutdown();
        if (r.interleave_scratch.len != 0) r.gpa.free(r.interleave_scratch);
        r.nv12_ring.deinit(r.gpa);
        r.rgba_ring.deinit(r.gpa);
        if (is_android) {
            if (saved_vk_ctx) |*ctx| ctx.deinit();
        }
        r.* = undefined;
    }

    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        r.width = width;
        r.height = height;
        c.bgfx_reset(width, height, c.BGFX_RESET_VSYNC, c.BGFX_TEXTURE_FORMAT_COUNT);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(width), @intCast(height));
    }

    /// A bgfx texture handle a caller keeps across calls and repeatedly
    /// rebinds to new native pointers via PersistentTexture.rebind,
    /// instead of creating a fresh handle every time.
    pub const PersistentTexture = struct {
        handle: c.bgfx_texture_handle_t = .{ .idx = invalid_handle },
        width: u16 = 0,
        height: u16 = 0,

        /// A fresh handle every frame never survives long enough to
        /// clear bgfx's own override-timing contract (0 means not yet
        /// created from the main thread). Reusing the same handle,
        /// recreated only on a real size change, fixes that.
        pub fn rebind(self: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) c.bgfx_texture_handle_t {
            if (self.handle.idx == invalid_handle or self.width != width or self.height != height) {
                if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
                const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
                self.handle = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0);
                self.width = width;
                self.height = height;
            }
            if (self.handle.idx == invalid_handle) return self.handle;
            _ = c.bgfx_override_internal_texture_ptr(self.handle, native_ptr, 0);
            return self.handle;
        }

        pub fn deinit(self: *PersistentTexture) void {
            if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
            self.* = .{};
        }

        /// Uploads a copy of RGBA/BGRA `data` into this texture, creating or
        /// resizing on a dimension change. Mirrors uploadRgba's axis flip so a
        /// composited source matches the camera path, but owns its own texture
        /// so a multi-source composite never clobbers the shared upload cache.
        pub fn uploadCopy(self: *PersistentTexture, width: u16, height: u16, format: u32, data: [*]const u8, stride: u32) c.bgfx_texture_handle_t {
            if (self.handle.idx == invalid_handle or self.width != width or self.height != height) {
                if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
                const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
                self.handle = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0);
                self.width = width;
                self.height = height;
            }
            const bytes_wide = @as(u64, width) * height * 4;
            if (bytes_wide > std.math.maxInt(u32)) return self.handle;
            const mem = c.bgfx_alloc(@intCast(bytes_wide)) orelse return self.handle;
            const dst: [*]u8 = mem.*.data;
            // Both axes reversed (a half turn) matches uploadRgba's flip.
            image.argbRotate(data, stride, dst, @as(u32, width) * 4, width, height, .half) catch return self.handle;
            c.bgfx_update_texture_2d(self.handle, 0, 0, 0, 0, width, height, mem, std.math.maxInt(u16));
            return self.handle;
        }
    };

    /// Verifies the override actually landed, keeping pt's handle alive
    /// across a still-pending resolve. The just-created frame never
    /// overrides at all: bgfx recycles handle indices, and a dying
    /// predecessor in the backend slot reads as a landed override.
    pub fn wrapExternalRenderTarget(r: *Renderer, pt: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) ?c.bgfx_texture_handle_t {
        _ = r;
        if (pt.handle.idx == invalid_handle or pt.width != width or pt.height != height) {
            if (pt.handle.idx != invalid_handle) c.bgfx_destroy_texture(pt.handle);
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP | c.BGFX_TEXTURE_RT;
            pt.handle = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0);
            pt.width = width;
            pt.height = height;
            return null;
        }
        const resolved = c.bgfx_override_internal_texture_ptr(pt.handle, native_ptr, 0);
        if (resolved == 0) return null;
        return pt.handle;
    }

    /// Wraps a platform window (an encoder input surface on Android) as
    /// a render target - the zero-copy recording path where the encoder
    /// consumes the window's own buffers. The target has no sampleable
    /// texture; nothing can composite FROM it.
    pub fn createWindowTarget(nwh: *anyopaque, width: u16, height: u16) !OffscreenTarget {
        const framebuffer = c.bgfx_create_frame_buffer_from_nwh(nwh, width, height, c.BGFX_TEXTURE_FORMAT_BGRA8, c.BGFX_TEXTURE_FORMAT_COUNT);
        if (framebuffer.idx == invalid_handle) return error.FrameBufferCreate;
        return .{ .framebuffer = framebuffer, .texture = .{ .idx = invalid_handle } };
    }

    /// wrapExternalRenderTarget's Vulkan sibling: override is a no-op on
    /// that backend, so this creates the texture in one step via
    /// bgfx_create_texture_2d's own _external parameter instead. RGBA8,
    /// matching the AHardwareBuffer's real format.
    pub fn createAndroidBeautyRenderTarget(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?c.bgfx_texture_handle_t {
        if (!is_android) return null;
        const zc = if (r.zero_copy) |*z| z else return null;
        const vk_image = zc.beauty_render_target.importRenderTarget(&zc.converter.ctx, @ptrCast(@alignCast(hardware_buffer)), width, height) catch return null;
        const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP | c.BGFX_TEXTURE_RT;
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, flags, null, vk_image);
        if (handle.idx == invalid_handle) return null;
        return handle;
    }

    /// PersistentTexture.rebind's Vulkan sibling, same reason as
    /// createAndroidBeautyRenderTarget above.
    pub fn wrapAndroidBeautyOutput(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?c.bgfx_texture_handle_t {
        if (!is_android) return null;
        const zc = if (r.zero_copy) |*z| z else return null;
        const vk_image = zc.beauty_import.importRgba(&zc.converter.ctx, @ptrCast(@alignCast(hardware_buffer)), width, height) catch return null;
        const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, flags, null, vk_image);
        if (handle.idx == invalid_handle) return null;
        return handle;
    }

    pub fn destroyTexture(r: *Renderer, handle: c.bgfx_texture_handle_t) void {
        _ = r;
        if (handle.idx != invalid_handle) c.bgfx_destroy_texture(handle);
    }

    /// bgfx's own native device handle for the active backend - an
    /// MTL::Device on Metal, whose pointer value is the same underlying
    /// id<MTLDevice> object metal-cpp wraps with no extra indirection.
    /// What lets a platform adapter (the beauty compositing bridge)
    /// create native resources bgfx can wrap back in without owning any
    /// bgfx dependency itself - the same separation PersistentTexture.
    /// rebind's own native_ptr argument already keeps.
    pub fn nativeDevice(r: *Renderer) ?*anyopaque {
        _ = r;
        const data = c.bgfx_get_internal_data();
        if (data == null or data.*.context == null) return null;
        return data.*.context;
    }

    /// True only once Vulkan actually initialized, not just on Android -
    /// false on the GLES fallback.
    pub fn isAndroidVulkan(r: *const Renderer) bool {
        return is_android and r.zero_copy != null;
    }

    /// Uploads a decoded, immutable image (a lens's LUT, say) as a real
    /// GPU texture, copying rgba once at creation - unlike the
    /// override-based wraps, there is no live external buffer behind
    /// this one to keep alive frame over frame. No instance state to
    /// touch, so this needs no receiver, the same as loadLensProgram.
    pub fn createStaticTexture(width: u16, height: u16, rgba: []const u8) TextureHandle {
        return c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, c.bgfx_copy(rgba.ptr, @intCast(rgba.len)), 0);
    }

    /// Uploads a single-channel mask (a segmentation result, say) as a
    /// real GPU texture - the same immutable, copy-once shape as
    /// createStaticTexture, just one byte per pixel instead of four,
    /// since a mask has no color to carry.
    pub fn createMaskTexture(width: u16, height: u16, mask: []const u8) TextureHandle {
        return c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_R8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, c.bgfx_copy(mask.ptr, @intCast(mask.len)), 0);
    }

    /// A single-channel R8 mask texture reused across frames: created on the
    /// first upload and on any size change, updated in place otherwise, so a
    /// per-frame mask never churns a GPU texture. Destroyed once at teardown.
    pub const DynamicMask = struct {
        handle: c.bgfx_texture_handle_t = .{ .idx = invalid_handle },
        width: u16 = 0,
        height: u16 = 0,

        /// Replaces the mask's pixels, recreating the texture only when the
        /// size changes; bgfx copies the bytes, so the caller may reuse them.
        pub fn upload(self: *DynamicMask, width: u16, height: u16, mask: []const u8) TextureHandle {
            if (self.handle.idx == invalid_handle or self.width != width or self.height != height) {
                if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
                const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
                self.handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_R8, flags, null, 0);
                self.width = width;
                self.height = height;
            }
            c.bgfx_update_texture_2d(self.handle, 0, 0, 0, 0, width, height, c.bgfx_copy(mask.ptr, @intCast(mask.len)), std.math.maxInt(u16));
            return self.handle;
        }

        pub fn deinit(self: *DynamicMask) void {
            if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
            self.* = .{};
        }

        /// True once a mask has been uploaded, so its texture is live.
        pub fn valid(self: DynamicMask) bool {
            return self.handle.idx != invalid_handle;
        }
    };

    /// A mutable BGRA texture whose pixels are replaced each frame - a
    /// video clip's decoded frame lands here. BGRA8 matches the byte order
    /// the platform decoders vend, so the upload needs no channel swap.
    pub fn createDynamicBgraTexture(width: u16, height: u16) TextureHandle {
        return c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_BGRA8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, null, 0);
    }

    /// Replaces a dynamic BGRA texture's pixels with a freshly decoded
    /// frame; bgfx copies the bytes, so the caller may reuse the buffer.
    pub fn updateDynamicBgraTexture(handle: TextureHandle, width: u16, height: u16, bgra: []const u8) void {
        c.bgfx_update_texture_2d(handle, 0, 0, 0, 0, width, height, c.bgfx_copy(bgra.ptr, @intCast(bgra.len)), std.math.maxInt(u16));
    }

    /// Full-screen quad geometry and the view's transform, shared by
    /// submitPreview and submitShaderPass - the two differ only in which
    /// program and textures they bind afterward.
    fn setupFullScreenQuad(r: *Renderer, view_id: c.bgfx_view_id_t, rotation_degrees: u32, mirror: bool) bool {
        var tvb: c.bgfx_transient_vertex_buffer_t = undefined;
        var tib: c.bgfx_transient_index_buffer_t = undefined;
        if (c.bgfx_get_avail_transient_vertex_buffer(4, &r.layout) < 4) return false;
        if (c.bgfx_get_avail_transient_index_buffer(6, false) < 6) return false;
        c.bgfx_alloc_transient_vertex_buffer(&tvb, 4, &r.layout);
        c.bgfx_alloc_transient_index_buffer(&tib, 6, false);

        // A tile restricts the sampled region to its part of the virtual output; the quad still
        // fills the tile's target. Turning and mirroring ride the sampling rather than a transform
        // on the quad, which is what lets them tile: a rotated quad spins within its own target,
        // so every tile would turn about its own centre instead of the picture turning once.
        const uv_l: f32 = if (r.tile) |tl| tl.u0 else 0.0;
        const uv_r: f32 = if (r.tile) |tl| tl.u1 else 1.0;
        const uv_top: f32 = if (r.tile) |tl| tl.v0 else 0.0;
        const uv_bot: f32 = if (r.tile) |tl| tl.v1 else 1.0;
        const bl = sampleAt(uv_l, uv_bot, rotation_degrees, mirror);
        const br = sampleAt(uv_r, uv_bot, rotation_degrees, mirror);
        const tr = sampleAt(uv_r, uv_top, rotation_degrees, mirror);
        const tl_uv = sampleAt(uv_l, uv_top, rotation_degrees, mirror);
        const verts: [*][5]f32 = @ptrCast(@alignCast(tvb.data));
        verts[0] = .{ -1.0, -1.0, 0.0, bl[0], bl[1] };
        verts[1] = .{ 1.0, -1.0, 0.0, br[0], br[1] };
        verts[2] = .{ 1.0, 1.0, 0.0, tr[0], tr[1] };
        verts[3] = .{ -1.0, 1.0, 0.0, tl_uv[0], tl_uv[1] };
        const idx: [*]u16 = @ptrCast(@alignCast(tib.data));
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, i| idx[i] = v;

        _ = c.bgfx_set_transform(&math.Mat4.identity.cols, 1);

        const view = math.Mat4.identity;
        const proj = math.Mat4.ortho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0, .zero_to_one);
        c.bgfx_set_view_transform(view_id, &view.cols, &proj.cols);

        c.bgfx_set_transient_vertex_buffer(0, &tvb, 0, 4);
        c.bgfx_set_transient_index_buffer(&tib, 0, 6);
        return true;
    }

    /// The trivial RGBA passthrough program submitPreview's own bgra
    /// branch already draws with - exposed so a caller outside this
    /// module (the beauty compositing bridge, blitting a plain texture
    /// into a platform-shared target through submitShaderPass) can reach
    /// it without touching Renderer's fields directly, the same
    /// boundary every other cross-module access in this file already
    /// keeps.
    pub fn passthroughProgram(r: *Renderer) c.bgfx_program_handle_t {
        return r.rgba_program;
    }

    /// Draws the camera frame as the full-view preview into view_id.
    /// `rotation_degrees` spins the quad for sensor orientation; `mirror`
    /// flips horizontally for front cameras.
    pub fn submitPreview(r: *Renderer, view_id: c.bgfx_view_id_t, preview: PreviewFrame, rotation_degrees: u32, mirror: bool) void {
        if (!r.setupFullScreenQuad(view_id, rotation_degrees, mirror)) return;
        switch (preview) {
            .bgra => |f| {
                c.bgfx_set_texture(0, r.tex_color, f.texture, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(view_id, r.rgba_program, 0, c.BGFX_DISCARD_ALL);
            },
            .nv12 => |f| {
                const transform = yuvTransform(f.conversion);
                c.bgfx_set_uniform(r.yuv_uniform, &transform.cols, 1);
                c.bgfx_set_texture(0, r.tex_y, f.y, std.math.maxInt(u32));
                c.bgfx_set_texture(1, r.tex_uv, f.uv, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(view_id, r.nv12_program, 0, c.BGFX_DISCARD_ALL);
            },
        }
    }

    /// An offscreen color target a shader pass can render into and a
    /// later pass (or the same pass's successor in a chain) can sample
    /// as input - what makes more than one lens shader pass composable
    /// without each one fighting the others for the swap chain.
    pub const OffscreenTarget = struct {
        framebuffer: c.bgfx_frame_buffer_handle_t,
        texture: c.bgfx_texture_handle_t,
    };

    pub fn createOffscreenTarget(width: u16, height: u16) !OffscreenTarget {
        const framebuffer = c.bgfx_create_frame_buffer(width, height, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP);
        if (framebuffer.idx == invalid_handle) return error.FrameBufferCreate;
        const texture = c.bgfx_get_texture(framebuffer, 0);
        return .{ .framebuffer = framebuffer, .texture = texture };
    }

    /// A half-float (RGBA16F) offscreen target for HDR compositing, so a pass
    /// chain carries values past 1.0 and finer precision than 8-bit unorm. Falls
    /// back to the 8-bit target where the backend cannot render 16F (some
    /// WebGL2), so an HDR lens still composites, just without the extra range.
    pub fn createOffscreenTargetHdr(width: u16, height: u16) !OffscreenTarget {
        const caps = c.bgfx_get_caps();
        const fmt_idx: usize = @intCast(c.BGFX_TEXTURE_FORMAT_RGBA16F);
        const formats = caps.*.formats;
        const fmt_flags: u32 = formats[fmt_idx];
        if ((fmt_flags & @as(u32, c.BGFX_CAPS_FORMAT_TEXTURE_FRAMEBUFFER)) == 0) return createOffscreenTarget(width, height);
        const framebuffer = c.bgfx_create_frame_buffer(width, height, c.BGFX_TEXTURE_FORMAT_RGBA16F, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP);
        if (framebuffer.idx == invalid_handle) return createOffscreenTarget(width, height);
        const texture = c.bgfx_get_texture(framebuffer, 0);
        return .{ .framebuffer = framebuffer, .texture = texture };
    }

    pub fn destroyOffscreenTarget(target: OffscreenTarget) void {
        if (target.framebuffer.idx != invalid_handle) c.bgfx_destroy_frame_buffer(target.framebuffer);
    }

    /// One tile of a larger capture output: the UV sub-rect a full-screen
    /// pass samples (u0,v0 top-left, u1,v1 bottom-right). An exact remap of
    /// the whole-frame UVs, so a tile is byte-identical to the same pixels
    /// of a single full-size render.
    pub const Tile = struct {
        u0: f32,
        v0: f32,
        u1: f32,
        v1: f32,
    };

    /// Wraps an existing texture handle (typically one wrapExternalRenderTarget
    /// just produced, over a platform-shared surface) as a render target
    /// bgfx can draw into via setViewTarget - what lets a shared surface
    /// receive a bgfx draw instead of only ever being sampled from. The
    /// texture's own lifecycle stays with whoever created it; destroying
    /// the returned target (destroyOffscreenTarget, same as any other
    /// OffscreenTarget) never touches it.
    pub fn createExternalTarget(handle: c.bgfx_texture_handle_t) !OffscreenTarget {
        const framebuffer = c.bgfx_create_frame_buffer_from_handles(1, &handle, false);
        if (framebuffer.idx == invalid_handle) return error.FrameBufferCreate;
        return .{ .framebuffer = framebuffer, .texture = handle };
    }

    /// Assigns view_id's render target: an offscreen target, or the
    /// swap chain itself when target is null (the last stage in a
    /// chain always presents to the swap chain). view_rect always
    /// matches the target's own size, offscreen or not.
    pub fn setViewTarget(view_id: c.bgfx_view_id_t, target: ?OffscreenTarget, width: u16, height: u16) void {
        c.bgfx_set_view_frame_buffer(view_id, if (target) |offscreen| offscreen.framebuffer else .{ .idx = invalid_handle });
        c.bgfx_set_view_rect(view_id, 0, 0, width, height);
    }

    /// Draws one lens shader.pass node as a full-screen pass into
    /// view_id: input_texture through the s_texColor sampler every lens
    /// fragment shader is authored against, and the node's named mask
    /// channel (or the all-foreground default) through s_texMask.
    /// bgfx blend state from BGFX_STATE_BLEND_FUNC(src, dst): the pre-shifted
    /// factor constants pack as f = src | (dst << 4), state = f | (f << 8).
    fn blendFunc(src: u64, dst: u64) u64 {
        const f = src | (dst << 4);
        return f | (f << 8);
    }

    /// Draws one brush stroke's ribbon over view_id, blending over whatever the
    /// view holds. `verts` is x, y in screen space then r, g, b, a per vertex.
    /// Neon passes additive for a glow, the rest blend on alpha. Uses a
    /// transient buffer, so it allocates nothing past the frame.
    pub fn submitBrush(r: *Renderer, view_id: c.bgfx_view_id_t, verts: [*]const f32, vertex_count: u32, additive: bool) void {
        if (vertex_count == 0) return;
        if (c.bgfx_get_avail_transient_vertex_buffer(vertex_count, &r.brush_layout) < vertex_count) return;
        var tvb: c.bgfx_transient_vertex_buffer_t = undefined;
        c.bgfx_alloc_transient_vertex_buffer(&tvb, vertex_count, &r.brush_layout);
        const floats = vertex_count * 6; // x, y, r, g, b, a
        const dst: [*]f32 = @ptrCast(@alignCast(tvb.data));
        @memcpy(dst[0..floats], verts[0..floats]);
        c.bgfx_set_transient_vertex_buffer(0, &tvb, 0, vertex_count);
        const src_alpha: u64 = c.BGFX_STATE_BLEND_SRC_ALPHA;
        const blend = if (additive)
            blendFunc(src_alpha, c.BGFX_STATE_BLEND_ONE)
        else
            blendFunc(src_alpha, c.BGFX_STATE_BLEND_INV_SRC_ALPHA);
        const state: u64 = @as(u64, c.BGFX_STATE_WRITE_RGB) | @as(u64, c.BGFX_STATE_WRITE_A) | blend;
        c.bgfx_set_state(state, 0);
        r.setMeshTile();
        c.bgfx_submit(view_id, r.brush_program, 0, c.BGFX_DISCARD_ALL);
    }

    pub fn submitShaderPass(r: *Renderer, view_id: c.bgfx_view_id_t, program: c.bgfx_program_handle_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Like submitShaderPass but also binds a generative texture to the reserved
    /// s_generated sampler (stage 1), so a material graph whose `generated`
    /// texture node samples it draws a prompt-generated map into the material.
    pub fn submitShaderPassGenerated(r: *Renderer, view_id: c.bgfx_view_id_t, program: c.bgfx_program_handle_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, generated_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_generated, generated_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Clears `target` to opaque black across the whole frame, so any region a
    /// multi-source composite leaves uncovered shows a defined backdrop instead
    /// of stale contents. The touch forces the clear with no draw.
    pub fn clearComposite(view_id: c.bgfx_view_id_t, target: OffscreenTarget, width: u16, height: u16) void {
        c.bgfx_set_view_frame_buffer(view_id, target.framebuffer);
        c.bgfx_set_view_rect(view_id, 0, 0, width, height);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x000000ff, 1.0, 0);
        c.bgfx_touch(view_id);
    }

    /// Draws `source_tex` (RGBA) scaled to fill the destination rectangle (in
    /// `target` pixels) as one placed source of a composite - a viewport draw
    /// with the passthrough program, no clear so earlier sources stay under it.
    pub fn submitLayoutSource(r: *Renderer, view_id: c.bgfx_view_id_t, source_tex: c.bgfx_texture_handle_t, target: OffscreenTarget, dx: u16, dy: u16, dw: u16, dh: u16) void {
        c.bgfx_set_view_frame_buffer(view_id, target.framebuffer);
        c.bgfx_set_view_rect(view_id, @intCast(dx), @intCast(dy), dw, dh);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_NONE, 0, 1.0, 0);
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, source_tex, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.rgba_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one source into a sub-rectangle of `target` with the composite
    /// program: opacity, a matte, or a chroma-key from `params` (opacity, key
    /// mode, similarity, softness) and `chroma`, alpha-blended over what the
    /// target already holds. No clear, so the sources below it stay.
    pub fn submitCompositeSource(r: *Renderer, view_id: c.bgfx_view_id_t, source_tex: c.bgfx_texture_handle_t, mask_tex: c.bgfx_texture_handle_t, target: OffscreenTarget, dx: u16, dy: u16, dw: u16, dh: u16, params: [4]f32, chroma: [4]f32) void {
        c.bgfx_set_view_frame_buffer(view_id, target.framebuffer);
        c.bgfx_set_view_rect(view_id, @intCast(dx), @intCast(dy), dw, dh);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_NONE, 0, 1.0, 0);
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, source_tex, std.math.maxInt(u32));
        // Key mode 3 samples this per-source matte; other modes ignore it, but
        // the sampler must be bound because the shader declares it.
        c.bgfx_set_texture(2, r.tex_mask, mask_tex, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.composite_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.composite_chroma_uniform, &chroma, 1);
        const blend = blendFunc(c.BGFX_STATE_BLEND_SRC_ALPHA, c.BGFX_STATE_BLEND_INV_SRC_ALPHA);
        const state: u64 = @as(u64, c.BGFX_STATE_WRITE_RGB) | @as(u64, c.BGFX_STATE_WRITE_A) | blend;
        c.bgfx_set_state(state, 0);
        c.bgfx_submit(view_id, r.composite_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a sprite over the frame already in the view's target: narrows
    /// the view to the sprite's pixel rect and alpha-composites the image
    /// there at `opacity` through the shared composite program. The caller
    /// sets the target, so this works for an offscreen target or swap chain.
    pub fn submitSpriteAtRect(r: *Renderer, view_id: c.bgfx_view_id_t, sprite_tex: c.bgfx_texture_handle_t, dx: u16, dy: u16, dw: u16, dh: u16, opacity: f32, source_alpha: bool) void {
        c.bgfx_set_view_rect(view_id, @intCast(dx), @intCast(dy), dw, dh);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_NONE, 0, 1.0, 0);
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, sprite_tex, std.math.maxInt(u32));
        // Key mode 1 cuts the sprite by its own alpha (a cutout sticker's matte);
        // mode 0 is a flat opacity fill for an opaque sprite.
        const params = [4]f32{ opacity, if (source_alpha) 1 else 0, 0, 0 };
        const chroma = [4]f32{ 0, 0, 0, 0 };
        c.bgfx_set_uniform(r.composite_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.composite_chroma_uniform, &chroma, 1);
        const blend = blendFunc(c.BGFX_STATE_BLEND_SRC_ALPHA, c.BGFX_STATE_BLEND_INV_SRC_ALPHA);
        c.bgfx_set_state(@as(u64, c.BGFX_STATE_WRITE_RGB) | @as(u64, c.BGFX_STATE_WRITE_A) | blend, 0);
        c.bgfx_submit(view_id, r.composite_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a sprite as a quad rotated about its centre so an interactive
    /// sprite can be turned two-fingered. cx, cy is the centre and hw, hh the
    /// half extents in normalized frame coordinates; rotation is radians and
    /// aspect the output width over height, so the turn keeps the sprite shape.
    pub fn submitSpriteRotated(r: *Renderer, view_id: c.bgfx_view_id_t, sprite_tex: c.bgfx_texture_handle_t, cx: f32, cy: f32, hw: f32, hh: f32, rotation: f32, aspect: f32, opacity: f32, source_alpha: bool) void {
        var tvb: c.bgfx_transient_vertex_buffer_t = undefined;
        var tib: c.bgfx_transient_index_buffer_t = undefined;
        if (c.bgfx_get_avail_transient_vertex_buffer(4, &r.layout) < 4) return;
        if (c.bgfx_get_avail_transient_index_buffer(6, false) < 6) return;
        c.bgfx_alloc_transient_vertex_buffer(&tvb, 4, &r.layout);
        c.bgfx_alloc_transient_index_buffer(&tib, 6, false);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_NONE, 0, 1.0, 0);

        const cos_a = @cos(rotation);
        const sin_a = @sin(rotation);
        const corners = [4][2]f32{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } };
        const uvs = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
        const verts: [*][5]f32 = @ptrCast(@alignCast(tvb.data));
        for (corners, 0..) |cnr, i| {
            // Rotate in the aspect-corrected pixel space, then map the corner
            // to clip space with the frame's own y flip.
            const rx = cnr[0] * cos_a - cnr[1] * sin_a / aspect;
            const ry = cnr[0] * aspect * sin_a + cnr[1] * cos_a;
            const nx = (cx + rx) * 2.0 - 1.0;
            const ny = 1.0 - (cy + ry) * 2.0;
            verts[i] = .{ nx, ny, 0.0, uvs[i][0], uvs[i][1] };
        }
        const idx: [*]u16 = @ptrCast(@alignCast(tib.data));
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, i| idx[i] = v;

        const view = math.Mat4.identity;
        const proj = math.Mat4.ortho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0, .zero_to_one);
        c.bgfx_set_view_transform(view_id, &view.cols, &proj.cols);
        c.bgfx_set_transient_vertex_buffer(0, &tvb, 0, 4);
        c.bgfx_set_transient_index_buffer(&tib, 0, 6);
        c.bgfx_set_texture(0, r.tex_color, sprite_tex, std.math.maxInt(u32));
        const params = [4]f32{ opacity, if (source_alpha) 1 else 0, 0, 0 };
        const chroma = [4]f32{ 0, 0, 0, 0 };
        c.bgfx_set_uniform(r.composite_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.composite_chroma_uniform, &chroma, 1);
        const blend = blendFunc(c.BGFX_STATE_BLEND_SRC_ALPHA, c.BGFX_STATE_BLEND_INV_SRC_ALPHA);
        c.bgfx_set_state(@as(u64, c.BGFX_STATE_WRITE_RGB) | @as(u64, c.BGFX_STATE_WRITE_A) | blend, 0);
        c.bgfx_submit(view_id, r.composite_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Points `view_id` at a sub-rectangle of `target` with no clear, so the
    /// caller can draw the camera preview into one composite cell via
    /// submitPreview (which fills whatever viewport is set).
    pub fn setLayoutViewport(view_id: c.bgfx_view_id_t, target: OffscreenTarget, dx: u16, dy: u16, dw: u16, dh: u16) void {
        c.bgfx_set_view_frame_buffer(view_id, target.framebuffer);
        c.bgfx_set_view_rect(view_id, @intCast(dx), @intCast(dy), dw, dh);
        c.bgfx_set_view_clear(view_id, c.BGFX_CLEAR_NONE, 0, 1.0, 0);
    }

    /// Draws one lens lut.pass node as a full-screen pass into view_id:
    /// the frame on unit 0, the lens's own LUT texture on unit 1, the
    /// one fixed lut_program every lut.pass node shares (there is
    /// nothing per-lens to compile here, unlike shader.pass).
    pub fn submitLutPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, lut_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_lut, lut_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.lut_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens blend.pass node as a full-screen pass into
    /// view_id: the frame on unit 0, the lens's own background image on
    /// unit 1, the session's current segmentation mask on unit 2, the
    /// one fixed blend_program every blend.pass node shares.
    pub fn submitBlendPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, background_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, strength: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, 0, 0, 0 };
        c.bgfx_set_uniform(r.blend_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.blend_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one pass of beauty.face's separable blur input into
    /// view_id - one call for the horizontal tap, one for the vertical,
    /// step carrying the per-tap UV offset for whichever direction this
    /// call is.
    pub fn submitBlurPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, step: [2]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        const step_vec4 = [4]f32{ step[0], step[1], 0.0, 0.0 };
        c.bgfx_set_uniform(r.blur_step_uniform, &step_vec4, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.blur_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a depth-of-field pass into view_id: the frame on unit 0, the
    /// depth texture on unit 1, blurred toward the out-of-focus image by the
    /// depth distance from the focus plane. focus is 0..1 in the depth's
    /// near..far range, strength scales the falloff.
    pub fn submitDofPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, depth_texture: c.bgfx_texture_handle_t, focus: f32, strength: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, depth_texture, std.math.maxInt(u32));
        const params = [4]f32{ focus, strength, 0.006, 0.0 };
        c.bgfx_set_uniform(r.dof_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.dof_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a depth fog pass into view_id: the frame on unit 0, the depth on
    /// unit 1, faded toward `color` by depth scaled by `density`.
    pub fn submitFogPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, depth_texture: c.bgfx_texture_handle_t, color: [3]f32, density: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, depth_texture, std.math.maxInt(u32));
        const params = [4]f32{ color[0], color[1], color[2], density };
        c.bgfx_set_uniform(r.fog_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.fog_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a depth-edge outline pass into view_id: the frame on unit 0, the
    /// depth on unit 1, `color` drawn where the depth jump between neighbors
    /// exceeds `threshold`.
    pub fn submitOutlinePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, depth_texture: c.bgfx_texture_handle_t, color: [3]f32, threshold: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, depth_texture, std.math.maxInt(u32));
        const params = [4]f32{ color[0], color[1], color[2], threshold };
        c.bgfx_set_uniform(r.outline_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.outline_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Blends a solid color into the frame masked by the texture on unit 1,
    /// scaled by the mask value and opacity, so a face-part matte reads as a
    /// soft makeup layer. mask_texture is a single-channel mask, color is rgb
    /// 0..1, opacity 0..1. mode picks the fold, finish the sheen.
    pub fn submitTintPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, color: [3]f32, opacity: f32, mode: u8, finish: u8) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ color[0], color[1], color[2], opacity };
        c.bgfx_set_uniform(r.tint_uniform, &params, 1);
        const mode_params = [4]f32{ @floatFromInt(mode), 0, 0, 0 };
        c.bgfx_set_uniform(r.tint_mode_uniform, &mode_params, 1);
        const finish_params = [4]f32{ @floatFromInt(finish), 0, 0, 0 };
        c.bgfx_set_uniform(r.tint_finish_uniform, &finish_params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.tint_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Reveals the head over the frame: the composited frame on unit 0, the
    /// preserved camera frame on unit 1, and the head matte on unit 2, mixing
    /// the camera frame back in where the matte is set so content drawn behind
    /// the head is hidden by it. params is (grow x, grow y, softness, 0).
    pub fn submitOccluderPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, restore_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, params: [4]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_background, restore_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.occluder_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.occluder_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Isolates the face into view_id: the frame on unit 0 and the face matte on
    /// unit 1, keeping the frame where the matte is set and replacing the rest
    /// with `color`, feathered by `softness`. mask_texture is a single-channel
    /// matte, color rgb 0..1.
    pub fn submitCutoutPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, color: [3]f32, softness: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ color[0], color[1], color[2], softness };
        c.bgfx_set_uniform(r.cutout_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.cutout_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Lifts the segmented subject into a transparent-background cutout: the
    /// matte becomes the alpha, so the subject keeps the camera color and the
    /// rest goes clear, ready to draw at a rect as a movable sticker. Reuses the
    /// cutout uniform; only w (softness) matters, the color is unused.
    pub fn submitCutoutSticker(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, softness: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ 0, 0, 0, softness };
        c.bgfx_set_uniform(r.cutout_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.cutout_sticker_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Blends the frame toward a small neighbor average, masked by the texture
    /// on unit 1 and scaled by amount, so a named region reads smoother. amount
    /// 0..1; mask_texture is a single-channel mask.
    pub fn submitSmoothPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ amount, 0, 0, 0 };
        c.bgfx_set_uniform(r.smooth_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.smooth_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Runs one selective skin filter over view_id: the frame on unit 0 and the
    /// mask on unit 1, scaled by amount. mode 0 is a wider edge-aware smooth that
    /// evens spots, mode 1 pulls bright pixels back toward the local mean.
    pub fn submitRetouchPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, mode: f32, amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ mode, amount, 0, 0 };
        c.bgfx_set_uniform(r.retouch_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.retouch_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Refines a matte's edges into view_id with a guided joint-bilateral
    /// filter: the frame on unit 0 is the luma edge guide, the matte on unit 1
    /// the signal refined. params is (radius, sensitivity, strength); the
    /// output is the refined matte drawn as grayscale.
    pub fn submitMatteRefinePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, matte_texture: c.bgfx_texture_handle_t, params: [3]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, matte_texture, std.math.maxInt(u32));
        const packed_params = [4]f32{ params[0], params[1], params[2], 0 };
        c.bgfx_set_uniform(r.matte_refine_uniform, &packed_params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.matte_refine_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a motion-trail pass into view_id: the current frame on unit 0
    /// and the previous frame on unit 1, blended into an echo by `amount`.
    pub fn submitTrailPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, prev_texture: c.bgfx_texture_handle_t, amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_prev, prev_texture, std.math.maxInt(u32));
        const params = [4]f32{ amount, 0, 0, 0 };
        c.bgfx_set_uniform(r.trail_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.trail_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a screen-space reflection pass into view_id: the frame on unit 0,
    /// the depth on unit 1, mirroring the scene across the `plane` horizon into
    /// the floor below it and scaling the reflection by `strength` and depth.
    pub fn submitSsrPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, depth_texture: c.bgfx_texture_handle_t, strength: f32, plane: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, depth_texture, std.math.maxInt(u32));
        const params = [4]f32{ strength, plane, 0, 0 };
        c.bgfx_set_uniform(r.ssr_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.ssr_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a procedural sky pass into view_id: the frame on unit 0, the
    /// segmentation mask on unit 1, a top-to-bottom sky gradient behind the
    /// foreground shifted by the camera `pitch` and `yaw` and scaled by
    /// `intensity`.
    pub fn submitEnvPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, top: [3]f32, bottom: [3]f32, intensity: f32, pitch: f32, yaw: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ pitch, yaw, intensity, 0 };
        const top_v = [4]f32{ top[0], top[1], top[2], 0 };
        const bottom_v = [4]f32{ bottom[0], bottom[1], bottom[2], 0 };
        c.bgfx_set_uniform(r.env_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.env_top_uniform, &top_v, 1);
        c.bgfx_set_uniform(r.env_bottom_uniform, &bottom_v, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.env_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws env.pass's image variant into view_id: the frame on unit 0, the
    /// equirect environment on unit 1, the mask on unit 2. `rot` is the
    /// camera's world rotation as three basis rows; the shader turns each
    /// pixel's view ray by it, samples the equirect, and keeps the foreground.
    pub fn submitEnvmapPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, env_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, rot: [3][4]f32, intensity: f32, aspect: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_background, env_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ intensity, aspect, 0, 0 };
        c.bgfx_set_uniform(r.env_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.env_rot_uniform, &rot, 3);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.envmap_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens grade.pass node as a full-screen pass into view_id:
    /// the frame on unit 0 and its color adjustment in u_grade (three vec4:
    /// tone, white balance with hue, then posterize and invert), the one
    /// fixed grade_program every grade.pass node shares.
    pub fn submitGradePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, grade: [12]f32, mask_texture: c.bgfx_texture_handle_t, masked: bool) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        // The free u_grade[2].z slot carries the mask enable, so a masked grade
        // blends only inside the channel and an unmasked one grades the frame.
        var packed_grade = grade;
        packed_grade[10] = if (masked) 1 else 0;
        c.bgfx_set_uniform(r.grade_params_uniform, &packed_grade, 3);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.grade_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one dehaze.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_dehaze (strength, texel width, texel height, 0), the one
    /// fixed dehaze_program every node shares.
    pub fn submitDehazePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, strength: f32, texel_w: f32, texel_h: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, texel_w, texel_h, 0 };
        c.bgfx_set_uniform(r.dehaze_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.dehaze_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one relight.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_relight (strength, light dir x, light dir y, 0), the one
    /// fixed relight_program every node shares.
    pub fn submitRelightPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params3: [3]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ params3[0], params3[1], params3[2], 0 };
        c.bgfx_set_uniform(r.relight_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.relight_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one glare.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_glare (strength, threshold, 0, 0), the one fixed
    /// glare_program every node shares.
    pub fn submitGlarePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, strength: f32, threshold: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, threshold, 0, 0 };
        c.bgfx_set_uniform(r.glare_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.glare_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one vignette.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_vignette (strength, radius, 0, 0), the one fixed
    /// vignette_program every node shares.
    pub fn submitVignettePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, strength: f32, radius: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, radius, 0, 0 };
        c.bgfx_set_uniform(r.vignette_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.vignette_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lowlight.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_lowlight (strength, denoise, texel w, texel h), the one
    /// fixed lowlight_program every node shares.
    pub fn submitLowLightPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, strength: f32, denoise: f32, texel_w: f32, texel_h: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, denoise, texel_w, texel_h };
        c.bgfx_set_uniform(r.lowlight_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.lowlight_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one undistort.pass node as a full-screen pass into view_id: the frame
    /// on unit 0, u_undistort (k1, k2, strength, aspect), and u_undistortC (cx,
    /// cy normalized), the one fixed undistort_program every node shares.
    pub fn submitUndistortPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, k1: f32, k2: f32, strength: f32, aspect: f32, cx: f32, cy: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ k1, k2, strength, aspect };
        c.bgfx_set_uniform(r.undistort_params_uniform, &params, 1);
        var center = [4]f32{ cx, cy, 0, 0 };
        c.bgfx_set_uniform(r.undistort_center_uniform, &center, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.undistort_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one awb.pass node as a full-screen pass into view_id: the frame on
    /// unit 0, u_awb (gainR, gainG, gainB, strength), and u_awbLevel (black,
    /// white), the one fixed awb_program every node shares.
    pub fn submitAwbPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, gains: [3]f32, strength: f32, black: f32, white: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ gains[0], gains[1], gains[2], strength };
        c.bgfx_set_uniform(r.awb_params_uniform, &params, 1);
        var level = [4]f32{ black, white, 0, 0 };
        c.bgfx_set_uniform(r.awb_level_uniform, &level, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.awb_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one stabilize.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_stabilize (shift u, shift v, inset, strength), the one fixed
    /// stabilize_program every node shares.
    pub fn submitStabilizePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, shift: [2]f32, inset: f32, strength: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ shift[0], shift[1], inset, strength };
        c.bgfx_set_uniform(r.stabilize_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.stabilize_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one zoom.pass node as a full-screen pass into view_id: the frame on
    /// unit 0 and u_zoom (factor, center u, center v, 0), the one fixed zoom_program
    /// every node shares.
    pub fn submitZoomPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, factor: f32, cx: f32, cy: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ factor, cx, cy, 0 };
        c.bgfx_set_uniform(r.zoom_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.zoom_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one dereflect.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_dereflect (strength, texel width, texel height, 0), the one
    /// fixed dereflect_program every node shares.
    pub fn submitDereflectPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, strength: f32, texel_w: f32, texel_h: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ strength, texel_w, texel_h, 0 };
        c.bgfx_set_uniform(r.dereflect_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.dereflect_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one harmonize.pass node as a full-screen pass into view_id: the frame
    /// on unit 0, the region mask on unit 1, and u_harmonize (the foreground and
    /// background means and standard deviations the engine measured, plus strength
    /// and direction), the one fixed harmonize_program every node shares.
    pub fn submitHarmonizePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, fg_mean: [3]f32, fg_std: [3]f32, bg_mean: [3]f32, bg_std: [3]f32, strength: f32, direction: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        var params = [16]f32{
            fg_mean[0], fg_mean[1], fg_mean[2], strength,
            fg_std[0],  fg_std[1],  fg_std[2],  direction,
            bg_mean[0], bg_mean[1], bg_mean[2], 0,
            bg_std[0],  bg_std[1],  bg_std[2],  0,
        };
        c.bgfx_set_uniform(r.harmonize_params_uniform, &params, 4);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.harmonize_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one inpaint.pass node as a full-screen pass into view_id: the frame
    /// on unit 0, the removal mask on unit 1, and u_inpaint (search radius, frame
    /// aspect), the one fixed inpaint_program every node shares.
    pub fn submitInpaintPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, radius: f32, aspect: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        var params = [4]f32{ radius, aspect, 0, 0 };
        c.bgfx_set_uniform(r.inpaint_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.inpaint_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Blends a fresh inpaint fill toward the previous frame's fill inside the
    /// removal mask by `coherence`, so a video inpaint holds steady frame to
    /// frame. fresh_texture is this frame's fill, prev_texture last frame's.
    pub fn submitInpaintCoherence(r: *Renderer, view_id: c.bgfx_view_id_t, fresh_texture: c.bgfx_texture_handle_t, prev_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, coherence: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, fresh_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_background, prev_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        var params = [4]f32{ coherence, 0, 0, 0 };
        c.bgfx_set_uniform(r.coherence_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.inpaint_coherence_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one rolling.pass node as a full-screen pass into view_id: the frame
    /// on unit 0 and u_rolling (the per-row skew the engine derived from the
    /// orientation stream), the one fixed rolling_program every node shares.
    pub fn submitRollingPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, skew_x: f32, skew_y: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        var params = [4]f32{ skew_x, skew_y, 0, 0 };
        c.bgfx_set_uniform(r.rolling_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.rolling_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one parallax.pass node as a full-screen pass into view_id: the frame
    /// on unit 0, the submitted depth on unit 1, and u_parallax (the per-frame
    /// shift the engine derived from the orientation tilt, the focus plane, and
    /// the fill mode), the one fixed parallax_program every node shares.
    pub fn submitParallaxPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, depth_texture: c.bgfx_texture_handle_t, shift_x: f32, shift_y: f32, focus: f32, fill: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, depth_texture, std.math.maxInt(u32));
        var params = [4]f32{ shift_x, shift_y, focus, fill };
        c.bgfx_set_uniform(r.parallax_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.parallax_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens stylize.pass node as a full-screen pass into view_id:
    /// the frame on unit 0 and its filter in u_stylize (mode, strength,
    /// threshold, levels), the one fixed stylize_program every node shares.
    pub fn submitStylizePass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params: [4]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.stylize_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.stylize_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens warp.pass node as a full-screen pass into view_id: the
    /// frame on unit 0, the confine mask on unit 1, then u_warp, u_warpParams and
    /// u_warpExtra plus the liquify push points and radii, on the one fixed
    /// warp_program every node shares.
    pub fn submitWarpPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, warp: [4]f32, params: [4]f32, extra: [4]f32, points: *const [8][4]f32, fall: *const [8][4]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_depth, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.warp_uniform, &warp, 1);
        c.bgfx_set_uniform(r.warp_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.warp_extra_uniform, &extra, 1);
        c.bgfx_set_uniform(r.warp_points_uniform, points, 8);
        c.bgfx_set_uniform(r.warp_fall_uniform, fall, 8);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.warp_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// edge.pass's sobel stage into view_id: the frame on unit 0, u_edge as
    /// (mode, strength, invert, 0) - mode 0 outputs the edge magnitude,
    /// mode 1 the magnitude plus gradient direction canny reads - and the
    /// per-texel step in u_edgeTexel.
    pub fn submitEdgeSobel(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params: [4]f32, texel: [2]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.edge_uniform, &params, 1);
        const texel_vec4 = [4]f32{ texel[0], texel[1], 0.0, 0.0 };
        c.bgfx_set_uniform(r.edge_texel_uniform, &texel_vec4, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.edge_sobel_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// canny's non-maximum suppression into view_id: the packed magnitude and
    /// direction on unit 0, u_edge as (low, high, 0, 0) for the hysteresis
    /// band and u_edgeTexel for the along-gradient sample step.
    pub fn submitEdgeNms(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params: [4]f32, texel: [2]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.edge_uniform, &params, 1);
        const texel_vec4 = [4]f32{ texel[0], texel[1], 0.0, 0.0 };
        c.bgfx_set_uniform(r.edge_texel_uniform, &texel_vec4, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.edge_nms_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// canny's weak-pixel hysteresis into view_id: the suppressed edges on
    /// unit 0, u_edge.x the invert flag, u_edgeTexel the 3x3 neighbour step.
    pub fn submitEdgeHyst(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params: [4]f32, texel: [2]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.edge_uniform, &params, 1);
        const texel_vec4 = [4]f32{ texel[0], texel[1], 0.0, 0.0 };
        c.bgfx_set_uniform(r.edge_texel_uniform, &texel_vec4, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.edge_hyst_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// bloom.pass's bright-extract stage into view_id: the frame on unit 0,
    /// the bloom params (threshold, intensity) in u_bloom, writing only the
    /// highlights that clear the threshold into the bloom scratch target.
    pub fn submitBloomExtract(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, params: [4]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.bloom_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.bloom_extract_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// bloom.pass's composite stage into view_id: the original frame on
    /// unit 0, the blurred bright pass on unit 1, added back over the base
    /// scaled by intensity (u_bloom.y).
    pub fn submitBloomComposite(r: *Renderer, view_id: c.bgfx_view_id_t, base_texture: c.bgfx_texture_handle_t, bloom_texture: c.bgfx_texture_handle_t, params: [4]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, base_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_bloom, bloom_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.bloom_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.bloom_composite_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.face node (smooth+whiten) as a full-screen pass
    /// into view_id: the frame and its separable blur on units 0-1, the
    /// four whitening LUTs on units 2-5, matching gpupixel's own
    /// beauty_face_unit_filter.cc lookup set.
    pub fn submitBeautyFace(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mean_texture: c.bgfx_texture_handle_t, lookup_gray: c.bgfx_texture_handle_t, lookup_origin: c.bgfx_texture_handle_t, lookup_skin: c.bgfx_texture_handle_t, lookup_custom: c.bgfx_texture_handle_t, smooth_amount: f32, whiten_amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mean, mean_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_lookup_gray, lookup_gray, std.math.maxInt(u32));
        c.bgfx_set_texture(3, r.tex_lookup_origin, lookup_origin, std.math.maxInt(u32));
        c.bgfx_set_texture(4, r.tex_lookup_skin, lookup_skin, std.math.maxInt(u32));
        c.bgfx_set_texture(5, r.tex_lookup_custom, lookup_custom, std.math.maxInt(u32));
        const params = [4]f32{ smooth_amount, whiten_amount, 0.0, 0.0 };
        c.bgfx_set_uniform(r.beauty_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.beauty_face_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.reshape node (thin_face+big_eye) as a
    /// full-screen pass into view_id. face_points is the live tracked
    /// contour, 106 points as 212 floats (x0,y0,x1,y1,...) - the same
    /// flat layout core/tracking/face106.zig's base 106 points already
    /// fill, packed two points per vec4 with no repacking since that is
    /// already fs_beauty_reshape.sc's own u_facePoints layout.
    pub fn submitBeautyReshape(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, face_points: *const [face_point_vec4_count * 4]f32, aspect_ratio: f32, thin_face_amount: f32, big_eye_amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        const params = [4]f32{ aspect_ratio, thin_face_amount, big_eye_amount, 0.0 };
        c.bgfx_set_uniform(r.reshape_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.face_points_uniform, face_points, face_point_vec4_count);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.beauty_reshape_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one reshape.bank node as a full-screen pass into view_id. It
    /// reuses fs_beauty_reshape.sc's u_facePoints contour and u_reshapeParams
    /// header (aspect, presence, softness), adds the two derived anchors in
    /// u_reshapeHubs, and the sixty-six sculpt amounts padded into u_reshapeBank.
    pub fn submitReshapeBank(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, face_points: *const [face_point_vec4_count * 4]f32, hubs: [4]f32, bank: *const [66]f32, aspect_ratio: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        const header = [4]f32{ aspect_ratio, 1.0, 1.0, 0.0 };
        c.bgfx_set_uniform(r.reshape_params_uniform, &header, 1);
        c.bgfx_set_uniform(r.reshape_hubs_uniform, &hubs, 1);
        c.bgfx_set_uniform(r.face_points_uniform, face_points, face_point_vec4_count);
        var slots: [face_reshape_bank_vec4_count * 4]f32 = @splat(0);
        @memcpy(slots[0..66], bank);
        c.bgfx_set_uniform(r.reshape_bank_uniform, &slots, face_reshape_bank_vec4_count);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.reshape_bank_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one reshape.body node: a full-screen warp that sculpts the figure
    /// along the pose axis inside the body mask, so the background stays put.
    /// points holds six pose points (two per vec4), bank the eleven amounts.
    pub fn submitReshapeBody(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, points: *const [body_reshape_points_vec4_count * 4]f32, bank: *const [11]f32, aspect_ratio: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const header = [4]f32{ aspect_ratio, 0.0, 0.0, 0.0 };
        c.bgfx_set_uniform(r.body_params_uniform, &header, 1);
        c.bgfx_set_uniform(r.body_points_uniform, points, body_reshape_points_vec4_count);
        var slots: [body_reshape_bank_vec4_count * 4]f32 = @splat(0);
        @memcpy(slots[0..11], bank);
        c.bgfx_set_uniform(r.body_bank_uniform, &slots, body_reshape_bank_vec4_count);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.reshape_body_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.lipstick or beauty.blusher node: the 176-triangle
    /// mesh over the live tracked contour, not a full-screen pass -
    /// uv_buffer picks which effect (makeupLipstickUvBuffer/
    /// makeupBlushUvBuffer), positions is this frame's own 111 tracked
    /// points in 0-1 UV space (both the mesh's vertex position and,
    /// unchanged, its background sample point - vs_makeup.sc's own
    /// trick for reading the frame at exactly the screen position each
    /// triangle draws over).
    pub fn submitMakeup(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, makeup_texture: c.bgfx_texture_handle_t, uv_buffer: c.bgfx_vertex_buffer_handle_t, positions: *const [makeup_mesh.canonical_uv.len]f32, intensity: f32) void {
        c.bgfx_update_dynamic_vertex_buffer(r.makeup_position_buffer, 0, c.bgfx_copy(positions, @sizeOf(@TypeOf(positions.*))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.makeup_position_buffer, 0, makeup_mesh.canonical_uv.len / 2);
        c.bgfx_set_vertex_buffer(1, uv_buffer, 0, makeup_mesh.canonical_uv.len / 2);
        c.bgfx_set_index_buffer(r.makeup_index_buffer, 0, makeup_mesh.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, makeup_texture, std.math.maxInt(u32));
        const params = [4]f32{ intensity, 0.0, 0.0, 0.0 };
        c.bgfx_set_uniform(r.makeup_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        r.setMeshTile();
        c.bgfx_submit(view_id, r.makeup_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws the canonical face mesh over the frame: each vertex rides
    /// its tracked landmark (frame pixels in, zero-to-one frame UV out),
    /// canonical texture coordinates, the same program and blend the
    /// makeup mesh uses.
    /// Tells a screen-space mesh which slice of the picture it is drawing into. Whole-frame draws
    /// send the identity rect, so the shader's arithmetic is unchanged when nothing is tiled.
    fn setMeshTile(r: *const Renderer) void {
        const rect: [4]f32 = if (r.tile) |tl|
            .{ tl.u0, tl.v0, @max(tl.u1 - tl.u0, 1e-6), @max(tl.v1 - tl.v0, 1e-6) }
        else
            .{ 0.0, 0.0, 1.0, 1.0 };
        c.bgfx_set_uniform(r.mesh_tile_uniform, &rect, 1);
    }

    pub fn submitFaceMesh(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, mesh_texture: c.bgfx_texture_handle_t, landmarks: []const f32, frame_width: f32, frame_height: f32, intensity: f32) void {
        std.debug.assert(landmarks.len >= 468 * 3);
        var positions: [face_mesh_topology.vertex_count * 2]f32 = undefined;
        for (face_mesh_topology.vertex_landmarks, 0..) |landmark, at| {
            positions[at * 2] = landmarks[@as(usize, landmark) * 3] / frame_width;
            positions[at * 2 + 1] = landmarks[@as(usize, landmark) * 3 + 1] / frame_height;
        }
        c.bgfx_update_dynamic_vertex_buffer(r.face_mesh_position_buffer, 0, c.bgfx_copy(&positions, @sizeOf(@TypeOf(positions))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.face_mesh_position_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_vertex_buffer(1, r.face_mesh_uv_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_index_buffer(r.face_mesh_index_buffer, 0, face_mesh_topology.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, mesh_texture, std.math.maxInt(u32));
        const params = [4]f32{ intensity, 0.0, 0.0, 0.0 };
        c.bgfx_set_uniform(r.makeup_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        r.setMeshTile();
        c.bgfx_submit(view_id, r.makeup_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws the lens texture onto the canonical face mesh: each vertex rides
    /// its tracked landmark, samples the material at its face UV, keys the mask
    /// at the screen position, and blends over the frame by opacity and mode.
    pub fn submitFaceMaterial(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, material_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, landmarks: []const f32, frame_width: f32, frame_height: f32, opacity: f32, blend: f32) void {
        std.debug.assert(landmarks.len >= 468 * 3);
        var positions: [face_mesh_topology.vertex_count * 2]f32 = undefined;
        for (face_mesh_topology.vertex_landmarks, 0..) |landmark, at| {
            positions[at * 2] = landmarks[@as(usize, landmark) * 3] / frame_width;
            positions[at * 2 + 1] = landmarks[@as(usize, landmark) * 3 + 1] / frame_height;
        }
        c.bgfx_update_dynamic_vertex_buffer(r.face_mesh_position_buffer, 0, c.bgfx_copy(&positions, @sizeOf(@TypeOf(positions))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.face_mesh_position_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_vertex_buffer(1, r.face_mesh_uv_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_index_buffer(r.face_mesh_index_buffer, 0, face_mesh_topology.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, material_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ opacity, blend, 0.0, 0.0 };
        c.bgfx_set_uniform(r.paint_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        r.setMeshTile();
        c.bgfx_submit(view_id, r.paint_face_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Warps the donor face onto the tracked mesh: each vertex rides its tracked
    /// landmark, samples the donor at its canonical face UV, keys the mask at the
    /// screen position, and blends over the frame by opacity and the per-vertex
    /// seam feather, so the swap fades into the surrounding skin.
    pub fn submitFaceSwap(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, donor_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t, landmarks: []const f32, frame_width: f32, frame_height: f32, opacity: f32, feather: f32) void {
        std.debug.assert(landmarks.len >= 468 * 3);
        var positions: [face_mesh_topology.vertex_count * 2]f32 = undefined;
        face_mesh_topology.projectPositions(landmarks, frame_width, frame_height, &positions);
        c.bgfx_update_dynamic_vertex_buffer(r.face_mesh_position_buffer, 0, c.bgfx_copy(&positions, @sizeOf(@TypeOf(positions))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.face_mesh_position_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_vertex_buffer(1, r.face_mesh_uv_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_vertex_buffer(2, r.face_mesh_feather_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_index_buffer(r.face_mesh_index_buffer, 0, face_mesh_topology.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, donor_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        const params = [4]f32{ opacity, feather, 0.0, 0.0 };
        c.bgfx_set_uniform(r.swap_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        r.setMeshTile();
        c.bgfx_submit(view_id, r.face_swap_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws the lash strip over the frame: each eye's tip row is rebuilt from
    /// the tracked landmarks (length and curl scale off eye height), the strip
    /// UVs comb strands in the fragment stage, and the tint composites over the
    /// frame the same self-blend the makeup mesh uses.
    pub fn submitLashMesh(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, landmarks: []const f32, frame_width: f32, frame_height: f32, color: [4]f32, length: f32, curl: f32) void {
        std.debug.assert(landmarks.len >= 468 * 3);
        var positions: [lash_mesh.vertex_count * 2]f32 = undefined;
        lash_mesh.buildPositions(landmarks, frame_width, frame_height, length, curl, &positions);
        c.bgfx_update_dynamic_vertex_buffer(r.lash_position_buffer, 0, c.bgfx_copy(&positions, @sizeOf(@TypeOf(positions))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.lash_position_buffer, 0, lash_mesh.vertex_count);
        c.bgfx_set_vertex_buffer(1, r.lash_uv_buffer, 0, lash_mesh.vertex_count);
        c.bgfx_set_index_buffer(r.lash_index_buffer, 0, lash_mesh.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_uniform(r.lash_color_uniform, &color, 1);
        const shape = [4]f32{ lash_strand_count, lash_edge_softness, 0.0, 0.0 };
        c.bgfx_set_uniform(r.lash_shape_uniform, &shape, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.lash_program, 0, c.BGFX_DISCARD_ALL);
    }

    pub fn makeupLipstickUvBuffer(r: *const Renderer) c.bgfx_vertex_buffer_handle_t {
        return r.makeup_lipstick_uv_buffer;
    }

    pub fn makeupBlushUvBuffer(r: *const Renderer) c.bgfx_vertex_buffer_handle_t {
        return r.makeup_blush_uv_buffer;
    }

    /// A model.gltf node's geometry, uploaded once at load time - fixed
    /// topology, unlike the makeup mesh's per-frame-updated positions,
    /// so both buffers are static (not dynamic).
    /// A model mesh, static by default. A mesh with morph targets is
    /// built dynamic instead: its positions live in a dynamic buffer the
    /// morph pass re-uploads each frame, drawn by the same model program.
    pub const ModelMesh = struct {
        vertex_buffer: c.bgfx_vertex_buffer_handle_t = .{ .idx = invalid_handle },
        dynamic_vertex_buffer: c.bgfx_dynamic_vertex_buffer_handle_t = .{ .idx = invalid_handle },
        dynamic: bool = false,
        // A dynamic mesh carrying per-vertex normals in the lit layout, so a
        // deforming mesh (morph) re-uploads positions and normals together and
        // lights each frame instead of drawing flat.
        lit: bool = false,
        vertex_count: u32 = 0,
        index_buffer: c.bgfx_index_buffer_handle_t,
        index_count: u32,
    };

    /// A skinned model mesh: a dynamic position buffer re-uploaded each
    /// frame from the CPU skinning pass, and the mesh's own static index
    /// buffer. Drawn with the same model program as a static ModelMesh.
    pub const SkinnedMesh = struct {
        position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
        index_buffer: c.bgfx_index_buffer_handle_t,
        vertex_count: u32,
        index_count: u32,
        // A lit skinned mesh carries per-vertex normals in the lit layout, so a
        // body-skinned mesh re-uploads skinned positions and normals together and
        // lights each frame instead of drawing flat.
        lit: bool = false,
    };

    /// A simulated cloth grid: positions live in a dynamic vertex
    /// buffer updated every frame from the physics solver, the grid's
    /// triangles in a static index buffer.
    pub const ClothMesh = struct {
        position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
        index_buffer: c.bgfx_index_buffer_handle_t,
        vertex_count: u32,
        index_count: u32,
    };

    /// Strand hair drawn as line segments: a dynamic position buffer
    /// updated from the solver, static line indices per strand.
    pub const HairMesh = struct {
        position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
        index_buffer: c.bgfx_index_buffer_handle_t,
        vertex_count: u32,
        index_count: u32,
    };

    /// Builds a static mesh from positions and indices: real gpu-side
    /// geometry, uploaded once. Vertex data is interleaved into the
    /// same POSITION+TEXCOORD0 layout every full-screen-quad pass uses
    /// (r.layout), texcoord padded to zero since the model shader never
    /// samples one - this lets model draws reuse vs_lens_pass.sc rather
    /// than needing their own vertex stage.
    pub fn createModelMesh(r: *Renderer, positions: []const [3]f32, indices: []const u32) !ModelMesh {
        const interleaved = try r.gpa.alloc(f32, positions.len * 5);
        defer r.gpa.free(interleaved);
        for (positions, 0..) |p, i| {
            interleaved[i * 5 ..][0..5].* = .{ p[0], p[1], p[2], 0.0, 0.0 };
        }
        const vertex_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))), &r.layout, 0);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .vertex_buffer = vertex_buffer, .vertex_count = @intCast(positions.len), .index_buffer = index_buffer, .index_count = @intCast(indices.len) };
    }

    /// A model mesh that carries per-vertex normals for directional lighting,
    /// interleaved position/normal/texcoord into the lit layout. A vertex past
    /// the normal list (a mesh that shipped no normals) takes a +Z default, so
    /// it still draws, lit flat toward the camera.
    pub fn createLitModelMesh(r: *Renderer, positions: []const [3]f32, normals: []const [3]f32, indices: []const u32) !ModelMesh {
        const interleaved = try r.gpa.alloc(f32, positions.len * 8);
        defer r.gpa.free(interleaved);
        for (positions, 0..) |p, i| {
            const n = if (i < normals.len) normals[i] else [3]f32{ 0.0, 0.0, 1.0 };
            interleaved[i * 8 ..][0..8].* = .{ p[0], p[1], p[2], n[0], n[1], n[2], 0.0, 0.0 };
        }
        const vertex_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))), &r.lit_model_layout, 0);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .vertex_buffer = vertex_buffer, .vertex_count = @intCast(positions.len), .index_buffer = index_buffer, .index_count = @intCast(indices.len) };
    }

    /// Like createModelMesh but backs the positions with a dynamic buffer
    /// the morph pass re-uploads each frame; the initial upload is the
    /// mesh's rest positions, so it draws unmorphed until a weight moves.
    pub fn createDynamicModelMesh(r: *Renderer, positions: []const [3]f32, indices: []const u32) !ModelMesh {
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(@intCast(positions.len), &r.layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        const mesh: ModelMesh = .{ .dynamic_vertex_buffer = position_buffer, .dynamic = true, .vertex_count = @intCast(positions.len), .index_buffer = index_buffer, .index_count = @intCast(indices.len) };
        r.updateModelMesh(mesh, positions);
        return mesh;
    }

    /// A dynamic mesh in the lit layout: a morphing mesh under a light re-uploads
    /// its deformed positions and freshly computed normals together each frame,
    /// so it lights like a static lit mesh instead of drawing flat.
    pub fn createLitDynamicModelMesh(r: *Renderer, positions: []const [3]f32, normals: []const [3]f32, indices: []const u32) !ModelMesh {
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(@intCast(positions.len), &r.lit_model_layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        const mesh: ModelMesh = .{ .dynamic_vertex_buffer = position_buffer, .dynamic = true, .lit = true, .vertex_count = @intCast(positions.len), .index_buffer = index_buffer, .index_count = @intCast(indices.len) };
        r.updateLitModelMesh(mesh, positions, normals);
        return mesh;
    }

    /// Re-uploads deformed positions and their normals into a lit dynamic mesh,
    /// padding the texcoord to zero to match lit_model_layout. A no-op on a mesh
    /// that is not a lit dynamic one.
    pub fn updateLitModelMesh(r: *Renderer, mesh: ModelMesh, positions: []const [3]f32, normals: []const [3]f32) void {
        if (!mesh.dynamic or !mesh.lit) return;
        const count = @min(positions.len, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 8) orelse return;
        for (0..count) |i| {
            const n = if (i < normals.len) normals[i] else [3]f32{ 0.0, 0.0, 1.0 };
            interleaved[i * 8 ..][0..8].* = .{ positions[i][0], positions[i][1], positions[i][2], n[0], n[1], n[2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.dynamic_vertex_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    /// The reused interleave staging sized for `floats`, grown on the first
    /// larger mesh and reused thereafter. Null only if a grow ever fails, in
    /// which case the caller skips this update rather than allocating.
    fn interleaveStage(r: *Renderer, floats: usize) ?[]f32 {
        if (floats > r.interleave_scratch.len) {
            const grown = r.gpa.alloc(f32, floats) catch return null;
            if (r.interleave_scratch.len != 0) r.gpa.free(r.interleave_scratch);
            r.interleave_scratch = grown;
        }
        return r.interleave_scratch[0..floats];
    }

    /// Re-uploads deformed positions into a dynamic model mesh, padding
    /// the texcoord to zero to match r.layout. A no-op on a static mesh.
    pub fn updateModelMesh(r: *Renderer, mesh: ModelMesh, positions: []const [3]f32) void {
        if (!mesh.dynamic or mesh.lit) return;
        const count = @min(positions.len, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 5) orelse return;
        for (0..count) |i| {
            interleaved[i * 5 ..][0..5].* = .{ positions[i][0], positions[i][1], positions[i][2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.dynamic_vertex_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    pub fn destroyModelMesh(mesh: ModelMesh) void {
        if (mesh.dynamic) c.bgfx_destroy_dynamic_vertex_buffer(mesh.dynamic_vertex_buffer) else c.bgfx_destroy_vertex_buffer(mesh.vertex_buffer);
        c.bgfx_destroy_index_buffer(mesh.index_buffer);
    }

    /// Binds a model mesh's positions, dynamic buffer or static, so the
    /// three model draw paths do not each branch on the buffer kind.
    fn setModelVertexBuffer(mesh: ModelMesh) void {
        if (mesh.dynamic) {
            c.bgfx_set_dynamic_vertex_buffer(0, mesh.dynamic_vertex_buffer, 0, mesh.vertex_count);
        } else {
            c.bgfx_set_vertex_buffer(0, mesh.vertex_buffer, 0, std.math.maxInt(u32));
        }
    }

    /// Builds a skinned mesh: a dynamic position buffer sized to the
    /// vertex count and the mesh's own static index buffer. Positions
    /// start empty and land on the first updateSkinnedMesh.
    pub fn createSkinnedMesh(r: *Renderer, vertex_count: u32, indices: []const u32) !SkinnedMesh {
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(vertex_count, &r.layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .position_buffer = position_buffer, .index_buffer = index_buffer, .vertex_count = vertex_count, .index_count = @intCast(indices.len) };
    }

    /// Uploads CPU-skinned positions (three floats each) into the
    /// dynamic buffer, padding the texcoord to zero to match r.layout.
    pub fn updateSkinnedMesh(r: *Renderer, mesh: SkinnedMesh, positions: []const [3]f32) void {
        const count = @min(positions.len, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 5) orelse return;
        for (0..count) |i| {
            interleaved[i * 5 ..][0..5].* = .{ positions[i][0], positions[i][1], positions[i][2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    /// A skinned mesh in the lit layout: a body-skinned mesh under a light
    /// re-uploads its skinned positions and freshly computed normals together
    /// each frame, so it lights like a static lit mesh instead of drawing flat.
    pub fn createLitSkinnedMesh(r: *Renderer, vertex_count: u32, indices: []const u32) !SkinnedMesh {
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(vertex_count, &r.lit_model_layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .position_buffer = position_buffer, .index_buffer = index_buffer, .vertex_count = vertex_count, .index_count = @intCast(indices.len), .lit = true };
    }

    /// Uploads CPU-skinned positions and their normals into a lit skinned mesh,
    /// padding the texcoord to zero to match lit_model_layout.
    pub fn updateLitSkinnedMesh(r: *Renderer, mesh: SkinnedMesh, positions: []const [3]f32, normals: []const [3]f32) void {
        const count = @min(positions.len, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 8) orelse return;
        for (0..count) |i| {
            const n = if (i < normals.len) normals[i] else [3]f32{ 0.0, 0.0, 1.0 };
            interleaved[i * 8 ..][0..8].* = .{ positions[i][0], positions[i][1], positions[i][2], n[0], n[1], n[2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    /// drawSkinnedMesh through the lit program: the same content camera, plus the
    /// light and material uniforms so the skinned surface shades by its normals.
    pub fn drawLitSkinnedMesh(r: *Renderer, mesh_view: c.bgfx_view_id_t, mesh: SkinnedMesh, model_matrix: math.Mat4, base_color: [4]f32, light: [16]f32, material: [8]f32, aspect_ratio: f32) void {
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        var light_params = light;
        c.bgfx_set_uniform(r.light_uniform, &light_params, 4);
        var material_params = material;
        c.bgfx_set_uniform(r.material_uniform, &material_params, 2);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_lit_program, 0, c.BGFX_DISCARD_ALL);
    }

    pub fn destroySkinnedMesh(mesh: SkinnedMesh) void {
        c.bgfx_destroy_dynamic_vertex_buffer(mesh.position_buffer);
        c.bgfx_destroy_index_buffer(mesh.index_buffer);
    }

    /// Builds a cols x rows cloth mesh: a dynamic position buffer (in
    /// the shared POSITION+TEXCOORD0 layout, texcoord zero) and a
    /// static index buffer of the grid's two-triangles-per-cell.
    pub fn createClothMesh(r: *Renderer, cols: u32, rows: u32) !ClothMesh {
        const vertex_count = cols * rows;
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(vertex_count, &r.layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(r.gpa);
        var y: u32 = 0;
        while (y < rows - 1) : (y += 1) {
            var x: u32 = 0;
            while (x < cols - 1) : (x += 1) {
                const a = y * cols + x;
                const b = y * cols + x + 1;
                const cc = (y + 1) * cols + x;
                const d = (y + 1) * cols + x + 1;
                try indices.appendSlice(r.gpa, &.{ a, cc, b, b, cc, d });
            }
        }
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.items.ptr, @intCast(indices.items.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .position_buffer = position_buffer, .index_buffer = index_buffer, .vertex_count = vertex_count, .index_count = @intCast(indices.items.len) };
    }

    /// Like createClothMesh but for an arbitrary closed surface: a dynamic
    /// vertex buffer sized to the mesh and a static index buffer of the given
    /// triangles. Drives soft bodies whose topology is not a grid.
    pub fn createSoftMesh(r: *Renderer, vertex_count: u32, indices: []const u32) !ClothMesh {
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(vertex_count, &r.layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .position_buffer = position_buffer, .index_buffer = index_buffer, .vertex_count = vertex_count, .index_count = @intCast(indices.len) };
    }

    /// Uploads the solver's world-space vertices (three floats each)
    /// into the cloth's dynamic buffer, padding the texcoord to zero.
    pub fn updateClothMesh(r: *Renderer, mesh: ClothMesh, positions: []const f32) void {
        const count = @min(positions.len / 3, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 5) orelse return;
        for (0..count) |i| {
            interleaved[i * 5 ..][0..5].* = .{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    pub fn destroyClothMesh(mesh: ClothMesh) void {
        c.bgfx_destroy_dynamic_vertex_buffer(mesh.position_buffer);
        c.bgfx_destroy_index_buffer(mesh.index_buffer);
    }

    /// Builds a hair mesh: strand_count strands of verts each, a dynamic
    /// position buffer and static line indices connecting consecutive
    /// vertices within each strand.
    pub fn createHairMesh(r: *Renderer, strand_count: u32, verts: u32) !HairMesh {
        const vertex_count = strand_count * verts;
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(vertex_count, &r.layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(r.gpa);
        var s: u32 = 0;
        while (s < strand_count) : (s += 1) {
            var i: u32 = 0;
            while (i < verts - 1) : (i += 1) {
                const base = s * verts + i;
                try indices.appendSlice(r.gpa, &.{ base, base + 1 });
            }
        }
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.items.ptr, @intCast(indices.items.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .position_buffer = position_buffer, .index_buffer = index_buffer, .vertex_count = vertex_count, .index_count = @intCast(indices.items.len) };
    }

    pub fn updateHairMesh(r: *Renderer, mesh: HairMesh, positions: []const f32) void {
        const count = @min(positions.len / 3, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 5) orelse return;
        for (0..count) |i| {
            interleaved[i * 5 ..][0..5].* = .{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    pub fn destroyHairMesh(mesh: HairMesh) void {
        c.bgfx_destroy_dynamic_vertex_buffer(mesh.position_buffer);
        c.bgfx_destroy_index_buffer(mesh.index_buffer);
    }

    /// Draws hair strands as lines through the model program and camera.
    pub fn submitHair(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: HairMesh, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);

        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const model = math.Mat4.identity;
        _ = c.bgfx_set_transform(&model.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A | c.BGFX_STATE_PT_LINES, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a cloth mesh through the model program and camera - the
    /// dynamic-buffer sibling of submitModel; vertices are already in
    /// world space so the model matrix is identity.
    pub fn submitCloth(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ClothMesh, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);

        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const model = math.Mat4.identity;
        _ = c.bgfx_set_transform(&model.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Particles drawn as points: one dynamic position buffer, no index,
    /// streamed from the sim each frame.
    pub const ParticleMesh = struct {
        position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
        vertex_count: u32,
    };

    pub fn createParticleMesh(r: *Renderer, count: u32, fade: bool) !ParticleMesh {
        const vlayout = if (fade) &r.billboard_layout else &r.layout;
        const position_buffer = c.bgfx_create_dynamic_vertex_buffer(count, vlayout, c.BGFX_BUFFER_ALLOW_RESIZE);
        return .{ .position_buffer = position_buffer, .vertex_count = count };
    }

    pub fn updateParticleMesh(r: *Renderer, mesh: ParticleMesh, positions: []const f32) void {
        const count = @min(positions.len / 3, mesh.vertex_count);
        const interleaved = r.interleaveStage(count * 5) orelse return;
        for (0..count) |i| {
            interleaved[i * 5 ..][0..5].* = .{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], 0.0, 0.0 };
        }
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))));
    }

    /// Uploads already-interleaved sprite vertices (position, corner index,
    /// life, seed, velocity xy per vertex - eight floats) straight into the
    /// mesh; the writeBillboards output.
    pub fn updateParticleMeshFaded(mesh: ParticleMesh, faded: []const f32) void {
        const count = @min(faded.len / 12, mesh.vertex_count);
        c.bgfx_update_dynamic_vertex_buffer(mesh.position_buffer, 0, c.bgfx_copy(faded.ptr, @intCast(count * 12 * @sizeOf(f32))));
    }

    pub fn destroyParticleMesh(mesh: ParticleMesh) void {
        c.bgfx_destroy_dynamic_vertex_buffer(mesh.position_buffer);
    }

    /// The GPU particle sim's buffers: state (compute read/write, three vec4 per
    /// particle) and the billboards it writes (compute-write, drawn like any
    /// billboard mesh).
    pub const GpuParticleSim = struct {
        state_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
        billboard: ParticleMesh,
        count: u32,
        seeded: bool = false,
    };

    /// The forces the compute step applies beyond gravity, matching the CPU
    /// particle field so the two paths stay in step.
    pub const ParticleForces = struct {
        drag: f32 = 0,
        turbulence: f32 = 0,
        wind: [3]f32 = .{ 0, 0, 0 },
        curl: f32 = 0,
        attract: [3]f32 = .{ 0, 0, 0 },
        attract_strength: f32 = 0,
        vortex: f32 = 0,
    };

    /// Creates the GPU sim's buffers for `count` particles, or null when the
    /// compute program is not built for this backend (the CPU sim runs instead).
    pub fn createGpuParticleSim(r: *Renderer, count: u32) ?GpuParticleSim {
        if (r.particle_compute_program == null) return null;
        const billboard = c.bgfx_create_dynamic_vertex_buffer(count * 6, &r.billboard_layout, c.BGFX_BUFFER_COMPUTE_WRITE);
        if (billboard.idx == invalid_handle) return null;
        const state = c.bgfx_create_dynamic_vertex_buffer(count * 3, &r.vec4_layout, c.BGFX_BUFFER_COMPUTE_READ_WRITE);
        if (state.idx == invalid_handle) {
            c.bgfx_destroy_dynamic_vertex_buffer(billboard);
            return null;
        }
        return .{ .state_buffer = state, .billboard = .{ .position_buffer = billboard, .vertex_count = count * 6 }, .count = count };
    }

    /// Runs one sim step on the GPU: binds the state and billboard buffers, sets
    /// the params, and dispatches a thread group per 64 particles. The first
    /// call seeds the state (emit); later calls integrate.
    pub fn dispatchGpuParticles(r: *Renderer, view: c.bgfx_view_id_t, sim: *GpuParticleSim, dt: f32, gravity: f32, speed: f32, lifetime: f32, forces: ParticleForces) void {
        const program = r.particle_compute_program orelse return;
        const seed_flag: f32 = if (sim.seeded) 0.0 else 1.0;
        sim.seeded = true;
        const p1 = [4]f32{ dt, gravity, @floatFromInt(sim.count), seed_flag };
        const p2 = [4]f32{ speed, lifetime, forces.drag, forces.turbulence };
        const p3 = [4]f32{ forces.wind[0], forces.wind[1], forces.wind[2], forces.curl };
        const p4 = [4]f32{ forces.attract[0], forces.attract[1], forces.attract[2], forces.attract_strength };
        const p5 = [4]f32{ forces.vortex, 0, 0, 0 };
        c.bgfx_set_uniform(r.sim_params_uniform, &p1, 1);
        c.bgfx_set_uniform(r.sim_params2_uniform, &p2, 1);
        c.bgfx_set_uniform(r.sim_params3_uniform, &p3, 1);
        c.bgfx_set_uniform(r.sim_params4_uniform, &p4, 1);
        c.bgfx_set_uniform(r.sim_params5_uniform, &p5, 1);
        c.bgfx_set_compute_dynamic_vertex_buffer(0, sim.state_buffer, c.BGFX_ACCESS_READWRITE);
        c.bgfx_set_compute_dynamic_vertex_buffer(1, sim.billboard.position_buffer, c.BGFX_ACCESS_WRITE);
        const groups = (sim.count + 63) / 64;
        c.bgfx_dispatch(view, program, groups, 1, 1, 0);
    }

    pub fn destroyGpuParticleSim(sim: GpuParticleSim) void {
        c.bgfx_destroy_dynamic_vertex_buffer(sim.state_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(sim.billboard.position_buffer);
    }

    /// Draws particles over the frame. Opaque one-pixel points through the
    /// model program by default; when fade is set, each particle is a
    /// camera-facing alpha-blended sprite of sprite_size_ndc (ndc half-extent
    /// per axis) through the billboard program, dimmed by its remaining life.
    pub fn defaultSpriteTexture(r: *const Renderer) c.bgfx_texture_handle_t {
        return r.default_sprite_texture;
    }

    /// Applies the active capture tile as an off-center sub-frustum crop
    /// on a 3D projection, so a tiled 3D draw rasterizes only its tile's
    /// slice at the tile's resolution. The 2D passes crop by UV; 3D
    /// content crops in clip space, off the same tile rect.
    fn tiledProjection(r: *const Renderer, base: math.Mat4) math.Mat4 {
        const tl = r.tile orelse return base;
        const uw = tl.u1 - tl.u0;
        const vh = tl.v1 - tl.v0;
        const crop: math.Mat4 = .{ .cols = .{
            .{ 1.0 / uw, 0.0, 0.0, 0.0 },
            .{ 0.0, 1.0 / vh, 0.0, 0.0 },
            .{ 0.0, 0.0, 1.0, 0.0 },
            .{ (1.0 - tl.u0 - tl.u1) / uw, (tl.v0 + tl.v1 - 1.0) / vh, 0.0, 1.0 },
        } };
        return crop.mul(base);
    }

    pub fn submitParticles(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ParticleMesh, base_color: [4]f32, cool_color: [4]f32, aspect_ratio: f32, fade: bool, particle_params: [4]f32, particle_fx: [4]f32, glow: bool, sprite_texture: c.bgfx_texture_handle_t) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);

        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const model = math.Mat4.identity;
        _ = c.bgfx_set_transform(&model.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        if (fade) {
            c.bgfx_set_texture(0, r.tex_sprite, sprite_texture, std.math.maxInt(u32));
            c.bgfx_set_uniform(r.particle_cool_uniform, &cool_color, 1);
            c.bgfx_set_uniform(r.particle_size_uniform, &particle_params, 1);
            c.bgfx_set_uniform(r.particle_fx_uniform, &particle_fx, 1);
            // Glow blends additively (overlaps brighten); otherwise a plain
            // src-alpha composite.
            const dst = if (glow) c.BGFX_STATE_BLEND_ONE else c.BGFX_STATE_BLEND_INV_SRC_ALPHA;
            c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A | c.BGFX_STATE_BLEND_FUNC(c.BGFX_STATE_BLEND_SRC_ALPHA, dst), 0);
            c.bgfx_submit(mesh_view, r.billboard_program, 0, c.BGFX_DISCARD_ALL);
        } else {
            c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A | c.BGFX_STATE_PT_POINTS, 0);
            c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
        }
    }

    /// Draws a sorted anisotropic gaussian splat cloud: blits the frame, then
    /// draws the pre-oriented gaussian quads (already covariance-shaped and
    /// back-to-front sorted in `mesh`) with a premultiplied over-blend, so the
    /// sorted splats composite into a soft volume over the passed-through frame.
    pub fn submitSplats(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ParticleMesh, aspect_ratio: f32, scissor: ?[4]u16) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const model = math.Mat4.identity;
        _ = c.bgfx_set_transform(&model.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        // A portal confines the splats to a rect; the frame the blit laid down
        // shows outside it, so the cloud reads as a window into the splat world.
        if (scissor) |s| _ = c.bgfx_set_scissor(s[0], s[1], s[2], s[3]);
        // Premultiplied over: the fragment already folds opacity and the gaussian
        // tail into rgb, so a back-to-front pass composites the sorted splats.
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A | c.BGFX_STATE_BLEND_FUNC(c.BGFX_STATE_BLEND_ONE, c.BGFX_STATE_BLEND_INV_SRC_ALPHA), 0);
        c.bgfx_submit(mesh_view, r.splat_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws particle ribbons: blits the frame once, then draws the baked
    /// ribbon strips (a position-only triangle soup already in `mesh`) as flat
    /// colored triangles in the same content view the billboards use.
    pub fn submitRibbons(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ParticleMesh, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const model = math.Mat4.identity;
        _ = c.bgfx_set_transform(&model.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one model.gltf node: blit_view first blits the current
    /// frame into the shared target so the mesh's own triangles are
    /// the only pixels this draw changes (same reasoning submitMakeup's
    /// own blit step already documents, here as a separate bgfx view
    /// rather than a second draw in the same one, since the mesh needs
    /// its own real 3D view/projection - bgfx's view transform is a
    /// per-view, not per-draw, state, and the blit needs the flat
    /// ortho every other pass shares). mesh_view runs after blit_view
    /// (bgfx executes views in ascending id order) into the same
    /// target, so the mesh composites on top with no blend state
    /// needed. No depth test: a single flat mesh has nothing to
    /// self-occlude against; a lens with multiple overlapping model
    /// nodes would need the offscreen target to grow a depth
    /// attachment, real future work this lens does not need.
    pub fn submitModel(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        r.drawModelMesh(mesh_view, mesh, model_matrix, base_color, aspect_ratio);
    }

    /// The mesh half of submitModel, without the frame blit. The multi-face
    /// fan-out blits once through submitModel for the first face and draws
    /// each further face's model over it with this, so N faces cost one blit.
    pub fn drawModelMesh(r: *Renderer, mesh_view: c.bgfx_view_id_t, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, aspect_ratio: f32) void {
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        setModelVertexBuffer(mesh);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// submitModel's lit twin: blits the frame, then draws a normal-carrying
    /// mesh through the directional-light program. `light` is two vec4s: the
    /// world light direction and intensity, then its color and the ambient term;
    /// `material` is two vec4s: the emissive color and metallic, then roughness.
    pub fn submitLitModel(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, light: [16]f32, material: [8]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        r.drawLitModelMesh(mesh_view, mesh, model_matrix, base_color, light, material, aspect_ratio);
    }

    /// The mesh half of submitLitModel, without the frame blit, mirroring
    /// drawModelMesh for the multi-node fan-out.
    pub fn drawLitModelMesh(r: *Renderer, mesh_view: c.bgfx_view_id_t, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, light: [16]f32, material: [8]f32, aspect_ratio: f32) void {
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        setModelVertexBuffer(mesh);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        var light_params = light;
        c.bgfx_set_uniform(r.light_uniform, &light_params, 4);
        var material_params = material;
        c.bgfx_set_uniform(r.material_uniform, &material_params, 2);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_lit_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws mesh-mode particles: blits the frame once, then draws the shared
    /// base mesh at every particle position (xyz triples) scaled by `scale`,
    /// all into one mesh view, so a cloud of little 3D shapes costs one blit.
    pub fn submitParticleMeshes(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, positions: []const f32, scale: f32, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        const n = positions.len / 3;
        const sm = math.Mat4.scaling(.{ scale, scale, scale });
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const tm = math.Mat4.translation(.{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] });
            r.drawModelMesh(mesh_view, mesh, tm.mul(sm), base_color, aspect_ratio);
        }
    }

    /// Draws the same cloud of base meshes as submitParticleMeshes but in one
    /// instanced call: each particle's model matrix rides an instance buffer,
    /// so the whole cloud costs one draw instead of one per particle.
    pub fn submitParticleMeshesInstanced(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, positions: []const f32, scale: f32, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
        const n: u32 = @intCast(positions.len / 3);
        if (n == 0) return;
        const stride: u16 = 64;
        const avail = c.bgfx_get_avail_instance_data_buffer(n, stride);
        if (avail == 0) return;
        var idb: c.bgfx_instance_data_buffer_t = undefined;
        c.bgfx_alloc_instance_data_buffer(&idb, avail, stride);
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        const data: [*]f32 = @ptrCast(@alignCast(idb.data));
        const sm = math.Mat4.scaling(.{ scale, scale, scale });
        var i: u32 = 0;
        while (i < avail) : (i += 1) {
            const tm = math.Mat4.translation(.{ positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2] });
            const model = tm.mul(sm);
            const src: [*]const f32 = @ptrCast(&model.cols);
            var k: usize = 0;
            while (k < 16) : (k += 1) data[i * 16 + k] = src[k];
        }
        setModelVertexBuffer(mesh);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_instance_data_buffer(&idb, 0, avail);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_instanced_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws a skinned mesh from its dynamic position buffer under the
    /// body anchor matrix, otherwise identical to drawModelMesh.
    pub fn drawSkinnedMesh(r: *Renderer, mesh_view: c.bgfx_view_id_t, mesh: SkinnedMesh, model_matrix: math.Mat4, base_color: [4]f32, aspect_ratio: f32) void {
        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = r.tiledProjection(math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one));
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        c.bgfx_set_dynamic_vertex_buffer(0, mesh.position_buffer, 0, mesh.vertex_count);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// submitModel with the platform camera's own view and projection -
    /// world-anchored content renders from where the device actually
    /// is, not from the fixed content camera.
    pub fn submitModelWithCamera(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, model_matrix: math.Mat4, view: math.Mat4, projection: math.Mat4, base_color: [4]f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);

        const projection_tiled = r.tiledProjection(projection);
        c.bgfx_set_view_transform(mesh_view, &view.cols, &projection_tiled.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        setModelVertexBuffer(mesh);
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// The stated CPU path: copies NV12 planes into two cached updatable
    /// textures, recreated only when the size changes. The row copies go
    /// through bgfx's frame allocator, freed after submission; the cache
    /// itself is two textures, bounded and freed at shutdown.
    pub fn uploadNv12(r: *Renderer, width: u16, height: u16, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) !Nv12Textures {
        if (r.upload_cache) |cache| {
            if (cache.width != width or cache.height != height) {
                c.bgfx_destroy_texture(cache.y);
                c.bgfx_destroy_texture(cache.uv);
                r.upload_cache = null;
            }
        }
        if (r.upload_cache == null) {
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
            r.upload_cache = .{
                .y = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_R8, flags, null, 0),
                .uv = c.bgfx_create_texture_2d(width / 2, height / 2, false, 1, c.BGFX_TEXTURE_FORMAT_RG8, flags, null, 0),
                .width = width,
                .height = height,
            };
        }
        const cache = r.upload_cache.?;

        // One ring slot carries both planes so both references stay live
        // until bgfx consumes them; the tightly packed copies match the old
        // bgfx_alloc path byte for byte.
        const uv_width: usize = width;
        const uv_rows: usize = height / 2;
        const y_size: usize = @as(usize, width) * height;
        const uv_size: usize = uv_width * uv_rows;
        const slot = r.nv12_ring.next(r.gpa, y_size + uv_size) orelse return error.OutOfMemory;

        const y_dst = slot[0..y_size];
        for (0..height) |row| {
            @memcpy(y_dst[row * width ..][0..width], y[row * y_stride ..][0..width]);
        }
        c.bgfx_update_texture_2d(cache.y, 0, 0, 0, 0, width, height, c.bgfx_make_ref(y_dst.ptr, @intCast(y_size)), std.math.maxInt(u16));

        const uv_dst = slot[y_size..][0..uv_size];
        for (0..uv_rows) |row| {
            @memcpy(uv_dst[row * uv_width ..][0..uv_width], uv[row * uv_stride ..][0..uv_width]);
        }
        c.bgfx_update_texture_2d(cache.uv, 0, 0, 0, 0, width / 2, height / 2, c.bgfx_make_ref(uv_dst.ptr, @intCast(uv_size)), std.math.maxInt(u16));

        return .{ .y = cache.y, .uv = cache.uv };
    }

    /// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a
    /// browser's own canvas/video frame byte buffer, say, with no
    /// native GPU handle behind it for the zero-copy override path
    /// to use. Same cached-and-updated shape as uploadNv12 above,
    /// not createStaticTexture's one-shot immutable upload - a live
    /// camera frame changes every call, the same texture reused rather
    /// than recreated each time.
    pub fn uploadRgba(r: *Renderer, width: u16, height: u16, format: u32, rgba: [*]const u8, stride: u32) !c.bgfx_texture_handle_t {
        if (r.rgba_upload_cache) |cache| {
            if (cache.width != width or cache.height != height or cache.format != format) {
                c.bgfx_destroy_texture(cache.texture);
                r.rgba_upload_cache = null;
            }
        }
        if (r.rgba_upload_cache == null) {
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
            r.rgba_upload_cache = .{
                .texture = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0),
                .width = width,
                .height = height,
                .format = format,
            };
        }
        const cache = r.rgba_upload_cache.?;

        // Both axes reversed: bgfx's HTML5/WebGL2 backend samples (0,0)
        // as the last pixel of an uploaded 2D texture, not the first. The
        // reversed copy lands in a ring slot referenced through make_ref.
        const size_wide = @as(u64, width) * height * 4;
        if (size_wide > std.math.maxInt(u32)) return error.Unsupported;
        const size: usize = @intCast(size_wide);
        const dst = r.rgba_ring.next(r.gpa, size) orelse return error.OutOfMemory;
        image.argbRotate(rgba, stride, dst.ptr, @as(u32, width) * 4, width, height, .half) catch return error.Unsupported;
        c.bgfx_update_texture_2d(cache.texture, 0, 0, 0, 0, width, height, c.bgfx_make_ref(dst.ptr, @intCast(size)), std.math.maxInt(u16));

        return cache.texture;
    }

    /// Zero-copy submission of a camera hardware buffer: the adapter
    /// converts on its own queue and the returned handle is the ring
    /// texture holding the rgba frame. Unsupported formats and devices
    /// surface as errors the caller counts onto the declared copy path.
    pub fn submitHardwareBuffer(r: *Renderer, hardware_buffer: *anyopaque, width: u32, height: u32, conversion: math.color.Conversion) !c.bgfx_texture_handle_t {
        if (!is_android) return error.Unsupported;
        const zc = if (r.zero_copy) |*z| z else return error.Unsupported;
        const m = conversion.homogeneous();
        var matrix: [16]f32 = undefined;
        var index: usize = 0;
        inline for (0..4) |col| {
            inline for (0..4) |row| {
                matrix[index] = m.cols[col][row];
                index += 1;
            }
        }
        zc.converter.setConversion(matrix);
        const slot = try zc.converter.convert(@ptrCast(hardware_buffer), width, height);
        if (zc.width != width or zc.height != height) {
            for (&zc.textures, 0..) |*texture, ring_slot| {
                if (texture.idx != invalid_handle) c.bgfx_destroy_texture(texture.*);
                texture.* = c.bgfx_create_texture_2d(
                    @intCast(width),
                    @intCast(height),
                    false,
                    1,
                    c.BGFX_TEXTURE_FORMAT_RGBA8,
                    c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP,
                    null,
                    zc.converter.targetImage(@intCast(ring_slot)),
                );
            }
            zc.width = width;
            zc.height = height;
        }
        return zc.textures[slot];
    }

    pub fn touch(r: *Renderer) void {
        _ = r;
        c.bgfx_touch(0);
    }

    pub fn frame(r: *Renderer) u32 {
        _ = r;
        return c.bgfx_frame(0);
    }

    pub fn requestScreenshot(r: *Renderer, path: [*:0]const u8) void {
        _ = r;
        c.bgfx_request_screen_shot(.{ .idx = invalid_handle }, path);
    }

    /// Enqueues a pixel readback into `data` (sized to the texture's
    /// own width * height * 4); the texture must carry
    /// BGFX_TEXTURE_READ_BACK (createReadbackTexture). Returns the
    /// frame number the caller must reach via frame() before reading.
    pub fn readTexture(texture: TextureHandle, data: [*]u8) u32 {
        return c.bgfx_read_texture(texture, data, 0, 0);
    }

    /// A CPU-readable blit destination: render targets themselves are
    /// not readable on every backend, so readbacks blit into one of
    /// these first.
    pub fn createReadbackTexture(width: u16, height: u16) !TextureHandle {
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_TEXTURE_BLIT_DST | c.BGFX_TEXTURE_READ_BACK, null, 0);
        if (handle.idx == invalid_handle) return error.TextureCreate;
        return handle;
    }

    /// Enqueues a full-size copy of src into dst on view_id; blits run
    /// in view order, so a view id past every draw pass copies the
    /// finished frame.
    pub fn blitTexture(view_id: u8, dst: TextureHandle, src: TextureHandle, width: u16, height: u16) void {
        c.bgfx_blit(view_id, dst, 0, 0, 0, 0, src, 0, 0, 0, 0, width, height, 0);
    }
};

const t = std.testing;

test "compiled shader blobs carry the header bgfx parses" {
    inline for (.{ blobs.vs_preview_metal, blobs.vs_preview_spirv, blobs.vs_preview_essl }) |blob| {
        try t.expectEqualSlices(u8, "VSH", blob[0..3]);
    }
    inline for (.{ blobs.fs_preview_rgba_metal, blobs.fs_preview_nv12_spirv, blobs.fs_preview_nv12_essl }) |blob| {
        try t.expectEqualSlices(u8, "FSH", blob[0..3]);
    }
}

test "yuv transform embeds matrix and offset homogeneously" {
    const conv = math.color.yuvToRgb(.bt709, .video);
    const m = yuvTransform(conv);
    const rgb_direct = conv.apply(.{ 0.5, 0.4, 0.6 });
    const homogeneous = m.mulVec(.{ 0.5, 0.4, 0.6, 1.0 });
    try t.expect(math.vec.approxEq(rgb_direct, math.vec.vec3From4(homogeneous), 1.0e-6));
}

test "every backend has all three shaders embedded" {
    try t.expect(blobs.fs_preview_rgba_essl.len > 0);
    try t.expect(blobs.fs_preview_rgba_spirv.len > 0);
    try t.expect(blobs.vs_preview_essl.len > 0);
}

/// Where an output point reads from in the source, under a quarter turn and an optional mirror.
/// The inverse of the turn: the pixel being written asks which source pixel lands on it.
fn sampleAt(u: f32, v: f32, rotation_degrees: u32, mirror: bool) [2]f32 {
    const turned: [2]f32 = switch (rotation_degrees % 360) {
        90 => .{ 1.0 - v, u },
        180 => .{ 1.0 - u, 1.0 - v },
        270 => .{ v, 1.0 - u },
        else => .{ u, v },
    };
    return .{ if (mirror) 1.0 - turned[0] else turned[0], turned[1] };
}

test "an upright frame samples itself" {
    try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, sampleAt(0.25, 0.75, 0, false));
}

test "a quarter turn reads across" {
    try std.testing.expectEqual([2]f32{ 0.25, 0.25 }, sampleAt(0.25, 0.75, 90, false));
    try std.testing.expectEqual([2]f32{ 0.75, 0.25 }, sampleAt(0.25, 0.75, 180, false));
    try std.testing.expectEqual([2]f32{ 0.75, 0.75 }, sampleAt(0.25, 0.75, 270, false));
}

test "a mirror flips across the source, after the turn" {
    try std.testing.expectEqual([2]f32{ 0.75, 0.75 }, sampleAt(0.25, 0.75, 0, true));
    try std.testing.expectEqual([2]f32{ 0.75, 0.25 }, sampleAt(0.25, 0.75, 90, true));
}

test "the corners of a tile stay inside the source" {
    for ([_]u32{ 0, 90, 180, 270 }) |rot| {
        for ([_]bool{ false, true }) |mir| {
            for ([_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 0.5, 0.5 } }) |p| {
                const at = sampleAt(p[0], p[1], rot, mir);
                try std.testing.expect(at[0] >= 0.0 and at[0] <= 1.0);
                try std.testing.expect(at[1] >= 0.0 and at[1] <= 1.0);
            }
        }
    }
}
