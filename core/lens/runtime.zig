//! Splices one lens's parsed manifest into the session's frame graph and
//! drives it forward one tick at a time: compiled triggers fire their
//! actions on the false-to-true edge, param_ramp/param_set
//! update the lens's own live parameter values, and animation.Ramp
//! carries an in-flight ramp to its target at the fixed graph timestep.
//! This module knows the shape of a running lens - node splice/unsplice,
//! trigger firing, parameter state - and nothing about how any of it
//! actually gets drawn. It has no adapter dependency of its own; the
//! caller (core/abi) walks tick()'s returned effect values and is the
//! one that knows how to hand them to the engine.
//!
//! Node types are the closed, kit-versioned vocabulary a lens manifest
//! can name: the beauty family, shader passes, LUT passes, mask-driven
//! blend passes, and model.gltf are all wired here. This module has no
//! knowledge of a glTF asset's actual bytes - loading a .glb and
//! sampling its animation at a given elapsed time are the caller's job
//! (core/abi and the renderer); what this module owns is only whether
//! a model node is playing and for how long.

const std = @import("std");
const graph = @import("graph");
const manifest = @import("manifest");
const trigger = @import("trigger");
const logic = @import("logic");
const animation = @import("animation");

/// The beauty engine's six settable effects, named independently of
/// adapters/beauty.zig's own Effect enum - core/lens has no adapter
/// dependency - but numerically identical to it by construction; the
/// caller @enumFromInt's one into the other when dispatching.
pub const EffectSlot = enum(u3) {
    smooth = 0,
    whiten = 1,
    thin_face = 2,
    big_eye = 3,
    lipstick = 4,
    blush = 5,
};

pub const NodeType = enum { beauty_face, beauty_reshape, beauty_lipstick, beauty_blusher, shader_pass, lut_pass, blend_pass, blur_pass, grade_pass, bloom_pass, dof_pass, fog_pass, outline_pass, occluder_pass, cutout_pass, tint_pass, smooth_pass, retouch_pass, matte_refine, stylize_pass, edge_pass, warp_pass, reshape_bank, trail_pass, ssr_pass, env_pass, model_gltf, mesh_face, mesh_lashes, paint_face, draw_board, layout_composite, sprite_2d, text_2d, video_texture, matte_hair, face_swap, splat_cloud };

fn parseNodeType(type_str: []const u8) ?NodeType {
    if (std.mem.eql(u8, type_str, "beauty.face")) return .beauty_face;
    if (std.mem.eql(u8, type_str, "beauty.reshape")) return .beauty_reshape;
    if (std.mem.eql(u8, type_str, "beauty.lipstick")) return .beauty_lipstick;
    if (std.mem.eql(u8, type_str, "beauty.blusher")) return .beauty_blusher;
    if (std.mem.eql(u8, type_str, "shader.pass")) return .shader_pass;
    if (std.mem.eql(u8, type_str, "mesh.face")) return .mesh_face;
    if (std.mem.eql(u8, type_str, "mesh.lashes")) return .mesh_lashes;
    if (std.mem.eql(u8, type_str, "paint.face")) return .paint_face;
    if (std.mem.eql(u8, type_str, "face.swap")) return .face_swap;
    if (std.mem.eql(u8, type_str, "lut.pass")) return .lut_pass;
    if (std.mem.eql(u8, type_str, "blend.pass")) return .blend_pass;
    if (std.mem.eql(u8, type_str, "blur.pass")) return .blur_pass;
    if (std.mem.eql(u8, type_str, "grade.pass")) return .grade_pass;
    if (std.mem.eql(u8, type_str, "bloom.pass")) return .bloom_pass;
    if (std.mem.eql(u8, type_str, "dof.pass")) return .dof_pass;
    if (std.mem.eql(u8, type_str, "fog.pass")) return .fog_pass;
    if (std.mem.eql(u8, type_str, "outline.pass")) return .outline_pass;
    if (std.mem.eql(u8, type_str, "occluder.pass")) return .occluder_pass;
    if (std.mem.eql(u8, type_str, "cutout.pass")) return .cutout_pass;
    if (std.mem.eql(u8, type_str, "tint.pass")) return .tint_pass;
    if (std.mem.eql(u8, type_str, "smooth.pass")) return .smooth_pass;
    if (std.mem.eql(u8, type_str, "retouch.pass")) return .retouch_pass;
    if (std.mem.eql(u8, type_str, "matte.refine")) return .matte_refine;
    if (std.mem.eql(u8, type_str, "matte.hair")) return .matte_hair;
    if (std.mem.eql(u8, type_str, "stylize.pass")) return .stylize_pass;
    if (std.mem.eql(u8, type_str, "edge.pass")) return .edge_pass;
    if (std.mem.eql(u8, type_str, "warp.pass")) return .warp_pass;
    if (std.mem.eql(u8, type_str, "reshape.bank")) return .reshape_bank;
    if (std.mem.eql(u8, type_str, "trail.pass")) return .trail_pass;
    if (std.mem.eql(u8, type_str, "ssr.pass")) return .ssr_pass;
    if (std.mem.eql(u8, type_str, "env.pass")) return .env_pass;
    if (std.mem.eql(u8, type_str, "model.gltf")) return .model_gltf;
    if (std.mem.eql(u8, type_str, "draw.board")) return .draw_board;
    if (std.mem.eql(u8, type_str, "layout.composite")) return .layout_composite;
    if (std.mem.eql(u8, type_str, "sprite.2d")) return .sprite_2d;
    if (std.mem.eql(u8, type_str, "text.2d")) return .text_2d;
    if (std.mem.eql(u8, type_str, "video.texture")) return .video_texture;
    if (std.mem.eql(u8, type_str, "splat.cloud")) return .splat_cloud;
    return null;
}

/// A behavior node drives parameters or a sprite's texture each tick and draws
/// nothing itself, so it never joins the composite chain: the script, the logic
/// graph, the ml.infer model, and the diffusion restyle.
fn isBehaviorNode(type_str: []const u8) bool {
    return std.mem.eql(u8, type_str, "script") or
        std.mem.eql(u8, type_str, "logic.graph") or
        std.mem.eql(u8, type_str, "ml.infer") or
        std.mem.eql(u8, type_str, "diffusion");
}

const ParamSlot = struct { name: []const u8, effect: EffectSlot };

/// The param names each node type accepts and which effect slot each one
/// drives - the only place that mapping is declared. shader.pass,
/// lut.pass, blend.pass, and model.gltf have no effect-slot params of
/// their own: each one's id names the asset it runs (a shader source
/// file, a LUT image, a background image, or a .glb model), the same
/// way a node's id already resolves against other nodes for wiring.
fn paramSlotsFor(node_type: NodeType) []const ParamSlot {
    return switch (node_type) {
        .beauty_face => &.{
            .{ .name = "smooth", .effect = .smooth },
            .{ .name = "whiten", .effect = .whiten },
        },
        .beauty_reshape => &.{
            .{ .name = "thin_face", .effect = .thin_face },
            .{ .name = "big_eye", .effect = .big_eye },
        },
        .beauty_lipstick => &.{.{ .name = "blend", .effect = .lipstick }},
        .beauty_blusher => &.{.{ .name = "blend", .effect = .blush }},
        .shader_pass, .lut_pass, .blend_pass, .blur_pass, .grade_pass, .bloom_pass, .dof_pass, .fog_pass, .outline_pass, .occluder_pass, .cutout_pass, .tint_pass, .smooth_pass, .retouch_pass, .matte_refine, .matte_hair, .stylize_pass, .edge_pass, .warp_pass, .reshape_bank, .trail_pass, .ssr_pass, .env_pass, .model_gltf, .mesh_face, .mesh_lashes, .paint_face, .face_swap, .draw_board, .layout_composite, .sprite_2d, .text_2d, .video_texture, .splat_cloud => &.{},
    };
}

const ParamSource = union(enum) {
    literal: f32,
    parameter: u16,
};

const effect_slot_count = 6;

const LensNode = struct {
    graph_index: graph.NodeIndex,
    node_type: NodeType,
    bindings: [effect_slot_count]?ParamSource = @splat(null),
    /// Set only for .shader_pass, .lut_pass, .blend_pass, and
    /// .model_gltf nodes: the node's own id, which also names the asset
    /// it runs (shaders/<id>.glsl for shader.pass, assets/<id>.png for
    /// lut.pass and for blend.pass's background image, assets/<id>.glb
    /// for model.gltf) - a slice into the Lens's own retained manifest
    /// arena, not separately owned.
    asset_stem: ?[]const u8 = null,
    /// .shader_pass only: the named mask channel's index into
    /// manifest.mask_channels, when the manifest names one.
    mask_channel: ?u8 = null,
    /// .model_gltf only: the node anchors to the tracked face.
    face_anchor: bool = false,
    /// .model_gltf only: a face-anchored model retargets the tracked expression
    /// onto its morph targets (an avatar of the user's face).
    retarget: bool = false,
    /// .model_gltf only: the model drives its jaw-open morph from the audio
    /// envelope, so it mouths speech.
    talk: bool = false,
    body_anchor: bool = false,
    skeleton_anchor: bool = false,
    world_anchor: bool = false,
    physics: ?manifest.PhysicsBody = null,
    cloth: ?manifest.ClothField = null,
    balloon: ?manifest.BalloonField = null,
    hair: ?manifest.HairField = null,
    particles: ?manifest.ParticleField = null,
    /// .model_gltf only: the turntable gesture control, when the node declares one.
    control: ?manifest.ModelControl = null,
    /// .model_gltf only: a parameter name per animation clip whose live
    /// value is that clip's blend weight; empty plays the first clip.
    /// Slices into the retained manifest arena, not separately owned.
    clip_weights: []const []const u8 = &.{},
    /// .model_gltf only: a parameter name per morph target whose live
    /// value is that target's blend weight; empty leaves the mesh
    /// unmorphed. Slices into the retained manifest arena.
    morph_weights: []const []const u8 = &.{},
    /// .grade_pass only: the node's parametric color grade.
    grade: ?manifest.GradeField = null,
    /// .bloom_pass only: the node's glow threshold and intensity.
    bloom: ?manifest.BloomField = null,
    /// .dof_pass only: the node's focus plane and blur strength.
    dof: ?manifest.DofField = null,
    /// .fog_pass only: the node's fog color and density.
    fog: ?manifest.FogField = null,
    /// .outline_pass only: the node's line color and depth threshold.
    outline: ?manifest.OutlineField = null,
    /// .occluder_pass only: the node's silhouette expand, edge softness, and
    /// the head-matte channel it reveals.
    occluder: ?manifest.OccluderField = null,
    /// .cutout_pass only: the node's background color, edge softness, and the
    /// face-matte channel it keeps.
    cutout: ?manifest.CutoutField = null,
    /// .tint_pass only: the node's color, opacity, and mask channel.
    tint: ?manifest.TintField = null,
    /// .smooth_pass only: the node's amount and mask channel.
    smooth: ?manifest.SmoothField = null,
    /// .paint_face only: the opacity, face region, and blend the node lays its
    /// texture onto the face with.
    paint: ?manifest.PaintField = null,
    /// .face_swap only: the opacity, seam feather, and optional region the donor
    /// face is warped onto the tracked face with.
    swap: ?manifest.SwapField = null,
    /// .mesh_lashes only: the colour, opacity, length, and curl of the lash
    /// strip the node rises off the upper lid.
    lashes: ?manifest.LashField = null,
    /// .retouch_pass only: the node's selective-filter mode, amount, and channel.
    retouch: ?manifest.RetouchField = null,
    /// .matte_refine only: the node's guided edge-refinement parameters and
    /// the mask channel (or depth) it refines.
    matte: ?manifest.MatteField = null,
    /// .matte_hair only: the guided-refinement parameters the source lifts the
    /// coarse hair class into the hair_matte channel with.
    hair_matte: ?manifest.HairMatteField = null,
    /// .stylize_pass only: the node's artistic mode and parameters.
    stylize: ?manifest.StylizeField = null,
    /// .edge_pass only: the node's detector mode and parameters.
    edge: ?manifest.EdgeField = null,
    /// .warp_pass only: the node's distortion mode and parameters.
    warp: ?manifest.WarpField = null,
    /// .reshape_bank only: the node's sixty-six per-region face sculpt amounts.
    reshape: ?manifest.ReshapeField = null,
    /// .trail_pass only: the node's motion-trail echo amount.
    trail: ?manifest.TrailField = null,
    /// .ssr_pass only: the node's reflection strength and floor plane.
    ssr: ?manifest.SsrField = null,
    /// .env_pass only: the node's sky gradient colors and intensity.
    env: ?manifest.EnvField = null,
    /// .layout_composite only: the head arrangement and camera blend the lens
    /// drives the composite with.
    layout: ?manifest.LayoutField = null,
    /// .sprite_2d only: the screen rect and opacity the node draws its
    /// image at.
    sprite: ?manifest.SpriteField = null,
    /// .text_2d only: the string, rect, opacity, and color the node draws.
    text: ?manifest.TextField = null,
    /// .video_texture only: the clip source, rect, opacity, and playback rate
    /// the node decodes and draws at.
    video: ?manifest.VideoField = null,
    /// .splat_cloud only: the model that lifts the frame to a point cloud and
    /// the billboard size and color it draws the splats with.
    splat: ?manifest.SplatField = null,
    /// .model_gltf only: microseconds since play_animation last fired
    /// for this node, null if it never has. Advances every tick() the
    /// same way a ramp does - once a trigger starts it, not before.
    model_elapsed_us: ?u64 = null,
};

/// One shader.pass node ready for the caller to load and draw - which
/// graph node it is, and the shader (shaders/<stem>.glsl, plus its
/// packaged shaders/<stem>.<profile>.bin variants) it names. This
/// module has no bgfx dependency of its own; the caller resolves the
/// stem into actual bytes and does the real rendering work.
pub const ShaderPassNode = struct {
    graph_index: graph.NodeIndex,
    shader_stem: []const u8,
    /// Index into manifest.mask_channels when the node names one.
    mask_channel: ?u8 = null,
};

/// One lut.pass node ready for the caller to load and draw - which
/// graph node it is, and the LUT image (assets/<stem>.png) it names.
pub const LutPassNode = struct {
    graph_index: graph.NodeIndex,
    lut_stem: []const u8,
};

/// One blend.pass node ready for the caller to load and draw - which
/// graph node it is, and the background image (assets/<stem>.png) it
/// swaps in behind the segmentation mask.
pub const BlendPassNode = struct {
    graph_index: graph.NodeIndex,
    background_stem: []const u8,
};

/// One model.gltf node ready for the caller to load and draw - which
/// graph node it is, and the .glb (assets/<stem>.glb) it names.
pub const ModelNode = struct {
    graph_index: graph.NodeIndex,
    model_stem: []const u8,
    /// The lens-format node id, so cross-node references (a physics
    /// chain naming its anchor) resolve at draw setup.
    node_id: []const u8,
    face_anchor: bool = false,
    retarget: bool = false,
    talk: bool = false,
    body_anchor: bool = false,
    skeleton_anchor: bool = false,
    world_anchor: bool = false,
    physics: ?manifest.PhysicsBody = null,
    cloth: ?manifest.ClothField = null,
    balloon: ?manifest.BalloonField = null,
    hair: ?manifest.HairField = null,
    particles: ?manifest.ParticleField = null,
    control: ?manifest.ModelControl = null,
};

/// One mesh.face node ready for the caller to load and draw - which
/// graph node it is, and the texture (assets/<stem>.png) it warps over
/// the tracked face.
pub const MeshFaceNode = struct {
    graph_index: graph.NodeIndex,
    texture_stem: []const u8,
};

/// One mesh.lashes node ready for the caller to draw - which graph node it
/// is, and the lash strip's colour (rgb, opacity), length, and curl. It ships
/// no asset; the strip is built from the tracked eye landmarks each frame.
pub const LashNode = struct {
    graph_index: graph.NodeIndex,
    color: [4]f32,
    length: f32,
    curl: f32,
};

/// One paint.face node ready for the caller to load and draw - which graph
/// node it is, the texture (assets/<stem>.png) it warps over the tracked
/// face, and the region, opacity, and blend it lays it on the skin with.
pub const PaintFaceNode = struct {
    graph_index: graph.NodeIndex,
    texture_stem: []const u8,
    /// The face region the material is confined to, null for the whole face.
    mask_channel: ?u8,
    opacity: f32,
    /// 0 blend straight over, 1 multiply (ink tattoo), 2 screen (projection).
    blend: u8,
};

/// One face.swap node ready for the caller to load and draw - which graph node
/// it is, the donor face (assets/<stem>.png, in canonical face-mesh UVs) it
/// warps onto the tracked face, and the opacity, seam feather, and optional
/// region it blends the donor in with.
pub const FaceSwapNode = struct {
    graph_index: graph.NodeIndex,
    donor_stem: []const u8,
    /// An optional face region the swap is further confined to, null for the
    /// whole face mesh.
    mask_channel: ?u8,
    opacity: f32,
    feather: f32,
};

/// One sprite.2d node ready for the caller to load and draw - which graph
/// node it is, the image (assets/<stem>.png) it draws, and the normalized
/// screen rect and opacity it draws at.
pub const SpriteNode = struct {
    graph_index: graph.NodeIndex,
    image_stem: []const u8,
    rect: [4]f32,
    opacity: f32,
    /// A parameter name whose live value overrides opacity each frame, or
    /// empty for the static opacity.
    opacity_param: []const u8,
    /// Parameter names whose live values override the rect each frame, or empty
    /// for the static rect. A model output driving these moves the sprite.
    x_param: []const u8,
    y_param: []const u8,
    w_param: []const u8,
    h_param: []const u8,
    /// Frame count and rate for an animated sprite; frames == 1 is static.
    frames: u32,
    fps: f32,
    /// The direct-manipulation gestures this sprite responds to.
    interaction: manifest.Interaction,
    /// A segmentation channel that keys the sprite full-frame; null draws the
    /// sprite over the frame at its rect. mask_over selects the composite:
    /// false fills behind the region (greenscreen), true fills over it (restyle).
    mask_channel: ?u8,
    mask_over: bool,
    /// Over-mode restyle strength (0..1) and its optional live parameter name.
    mask_strength: f32,
    mask_strength_param: []const u8,
};

/// One splat.cloud node ready for the caller to load and draw - which graph node
/// it is, the model (assets/<model>) that lifts the frame to a point cloud, and
/// the billboard size and rgb color the splats draw with.
pub const SplatNode = struct {
    graph_index: graph.NodeIndex,
    model: []const u8,
    point: f32,
    color: [3]f32,
    /// True draws the model's output as a connected grid mesh; false draws it as
    /// a billboard point cloud.
    mesh: bool,
    /// True runs the model once on a submitted selfie (an avatar) rather than the
    /// live camera each tick.
    selfie: bool,
    /// True when the model emits rgb after xyz per point, so each splat carries
    /// its own color instead of the node color.
    colored: bool,
};

/// One text.2d node ready for the caller to rasterize and draw - which
/// graph node it is, the string it draws, the normalized rect and opacity,
/// and the rgb color its glyphs take.
pub const TextNode = struct {
    graph_index: graph.NodeIndex,
    content: []const u8,
    rect: [4]f32,
    opacity: f32,
    color: [3]u8,
    /// A parameter name whose live value overrides opacity each frame, or
    /// empty for the static opacity.
    opacity_param: []const u8,
    /// Rich-text styling: a vertical gradient base color, a drop shadow, and a
    /// stroke outline (each null/false is off).
    gradient: ?[3]u8,
    shadow: bool,
    stroke: ?[3]u8,
    /// Extrude the glyphs into a rotated 3D block mesh of this depth; 0 keeps
    /// the flat sprite text.
    depth: f32,
};

pub const VideoNode = struct {
    graph_index: graph.NodeIndex,
    /// The clip's asset stem (assets/<source>.mp4).
    source: []const u8,
    rect: [4]f32,
    opacity: f32,
    /// The rate the clip advances against the lens clock; 0 holds the first
    /// frame, and `loop` rewinds at the end rather than holding the last.
    fps: f32,
    loop: bool,
};

/// One grade.pass node ready for the caller to draw - which graph node
/// it is, and its color adjustment packed as three vec4 for u_grade: tone,
/// then white balance with hue, then posterize and invert.
pub const GradePassNode = struct {
    graph_index: graph.NodeIndex,
    grade: [12]f32,
};

/// One bloom.pass node ready for the caller to draw - which graph node it
/// is, and its glow packed as (threshold, intensity, 0, 0) for u_bloom.
pub const BloomPassNode = struct {
    graph_index: graph.NodeIndex,
    bloom: [4]f32,
};

pub const DofPassNode = struct {
    graph_index: graph.NodeIndex,
    focus: f32,
    strength: f32,
};

pub const FogPassNode = struct {
    graph_index: graph.NodeIndex,
    color: [3]f32,
    density: f32,
};

pub const OutlinePassNode = struct {
    graph_index: graph.NodeIndex,
    color: [3]f32,
    threshold: f32,
    /// The mask channel to outline, or null to trace the submitted depth.
    mask_channel: ?u8,
};

/// One occluder.pass node ready to draw - which graph node it is, its
/// silhouette expand and edge softness packed for u_occluder, and the head
/// matte channel it reveals over content drawn behind it.
pub const OccluderPassNode = struct {
    graph_index: graph.NodeIndex,
    params: [2]f32,
    mask_channel: u8,
};

/// One cutout.pass node ready to draw - which graph node it is, its background
/// color packed with the edge softness for u_cutout, and the face-matte channel
/// it keeps the frame through.
pub const CutoutPassNode = struct {
    graph_index: graph.NodeIndex,
    params: [4]f32,
    mask_channel: u8,
};

pub const TintPassNode = struct {
    graph_index: graph.NodeIndex,
    color: [3]f32,
    opacity: f32,
    /// The mask channel the tint fills, null when the node named none.
    mask_channel: ?u8,
    /// Color comes from the makeup reference, not the static rgb.
    from_reference: bool,
    /// How the color folds in: 0 blend, 1 multiply (darken), 2 screen (lighten).
    blend: u8,
    /// The finish: 0 matte (flat), 1 gloss, 2 shimmer, 3 metallic.
    finish: u8,
};

pub const SmoothPassNode = struct {
    graph_index: graph.NodeIndex,
    amount: f32,
    /// The mask channel the smooth acts on, null when the node named none.
    mask_channel: ?u8,
};

/// One retouch.pass node ready for the caller to draw - which graph node it is,
/// its filter packed for u_retouch (mode index then amount), and the mask
/// channel it acts on. mode 0 blemish (edge-aware smooth), 1 shine (highlight
/// suppression).
pub const RetouchPassNode = struct {
    graph_index: graph.NodeIndex,
    params: [2]f32,
    mask_channel: ?u8,
};

/// One matte.refine node ready for the caller to draw - which graph node it
/// is, its guided-filter parameters packed for u_matteRefine (radius,
/// sensitivity, strength), and the mask channel it refines (null refines the
/// submitted depth instead).
pub const MattePassNode = struct {
    graph_index: graph.NodeIndex,
    params: [3]f32,
    mask_channel: ?u8,
};

/// One stylize.pass node ready for the caller to draw - which graph node it
/// is, and its artistic filter packed for u_stylize: the mode index, then
/// strength, edge threshold, and colour quantization levels.
pub const StylizePassNode = struct {
    graph_index: graph.NodeIndex,
    params: [4]f32,
};

/// One edge.pass node ready for the caller to draw - which graph node it is,
/// and its detector packed as (mode, low, high, blur_radius, strength, invert):
/// mode 0 draws a single-pass sobel, mode 1 the multi-pass canny chain.
pub const EdgePassNode = struct {
    graph_index: graph.NodeIndex,
    params: [6]f32,
};

/// One warp.pass node ready for the caller to draw - which graph node it is,
/// and its distortion flat-packed: a header (mode, center_x, center_y, radius,
/// strength, refractive_index, aspect_auto, symmetry, symmetry_x, point_count)
/// then the liquify points as (x, y, dx, dy) and their falloff radii. mode 0
/// glass_sphere, 1 sphere_refraction, 2 bulge, 3 pinch, 4 swirl, 5 liquify.
pub const WarpPassNode = struct {
    graph_index: graph.NodeIndex,
    params: [manifest.warp_params_len]f32,
    /// The mask channel the displacement is confined to, null when the node
    /// named none and the warp acts on the whole frame.
    mask_channel: ?u8,
};

/// One reshape.bank node ready for the caller to draw: which graph node it
/// is, and its sixty-six per-region sculpt amounts in the ReshapeField field
/// order, each in [-1,1] with 0 the identity. The caller pairs these with the
/// live tracked contour and submits them into the shared reshape bank shader.
pub const ReshapePassNode = struct {
    graph_index: graph.NodeIndex,
    params: [66]f32,
};

pub const TrailPassNode = struct {
    graph_index: graph.NodeIndex,
    amount: f32,
};

pub const SsrPassNode = struct {
    graph_index: graph.NodeIndex,
    strength: f32,
    plane: f32,
};

pub const EnvPassNode = struct {
    graph_index: graph.NodeIndex,
    top: [3]f32,
    bottom: [3]f32,
    intensity: f32,
    /// The equirect environment image's stem (assets/<stem>.png) when the
    /// node ships one, null for a plain gradient sky.
    image_stem: ?[]const u8,
};

pub const PassKind = enum { shader, lut, blend, blur, grade, bloom, dof, fog, outline, occluder, cutout, tint, smooth, retouch, matte, stylize, edge, warp, reshape, trail, ssr, env, model, mesh, lashes, paint, draw_board, sprite, hair_matte, face_swap, splat };

/// One matte.hair source node ready for the caller to draw - which graph node
/// it is, and its guided-filter parameters packed for the refine pass (radius,
/// sensitivity, strength). The source refines the coarse hair class against the
/// camera luma and publishes the result as the hair_matte channel.
pub const HairMattePassNode = struct {
    graph_index: graph.NodeIndex,
    params: [3]f32,
};

/// One shader.pass, lut.pass, blend.pass, or model.gltf node, tagged
/// with which - the caller's real draw order for a chain that may mix
/// any of the four, since the graph itself makes no distinction
/// between them beyond node_type.
pub const CompositePass = struct {
    graph_index: graph.NodeIndex,
    kind: PassKind,
};

pub const ActivateError = error{
    UnknownNodeId,
    UnknownParameter,
    UnsupportedNodeType,
} || std.mem.Allocator.Error || graph.topology.EditError;

/// One resolved (effect, value) pair for the caller to apply. tick()
/// returns these instead of touching an engine directly.
pub const AppliedEffect = struct { effect: EffectSlot, value: f32 };

/// The device haptic a lens asks for. The style names the feel; the host maps
/// it to the platform's own haptic vocabulary. Intensity is 0..1, a hint the
/// host may honor where the platform allows it.
pub const HapticStyle = enum(u8) { light, medium, heavy, soft, rigid, success, warning, failure };
pub const HapticEvent = struct { style: HapticStyle, intensity: f32 };

/// A compiled logic.graph node: the evaluatable graph, the parameter its output
/// drives each tick, and a reusable scratch buffer sized to the node count.
pub const CompiledLogicGraph = struct {
    graph: logic.Graph,
    output_param: []const u8,
    scratch: []f32,
};

fn hapticStyleFromName(name: []const u8) HapticStyle {
    return std.meta.stringToEnum(HapticStyle, name) orelse .medium;
}

pub const Lens = struct {
    gpa: std.mem.Allocator,
    manifest: manifest.Manifest,
    compiled_triggers: []trigger.Expression,
    trigger_was_true: []bool,
    param_values: []f32,
    ramps: []?animation.Ramp,
    nodes: []LensNode,
    /// Every distinct timer('name') this lens's triggers reference,
    /// each name individually owned (not a slice into a compiled
    /// trigger's own arena, so freeing timer_names never depends on
    /// compiled_triggers' own deinit order). timer_elapsed_us is a
    /// parallel array: microseconds since lens activation, running
    /// continuously (not trigger-gated - a timer is a clock a trigger
    /// reads, not a value a trigger's action starts).
    timer_names: [][]u8,
    timer_elapsed_us: []u64,
    /// The lens's counters, each individually owned. counter_values is a
    /// parallel array of persistent values a trigger's increment, reset, or set
    /// action changes; unlike a timer, a counter holds until an action moves it.
    counter_names: [][]u8,
    counter_values: []f64,
    /// Compiled logic.graph nodes and the arena that owns their nodes, scratch
    /// buffers and any signal-name slices; evaluated each tick to drive params.
    logic_arena: std.heap.ArenaAllocator,
    logic_graphs: []CompiledLogicGraph,
    /// This tick's parameter values as f64, so a logic graph's param leaf reads
    /// the live value; sized once at activation.
    tick_param_snapshot: []f64,
    /// Microseconds since activation, advanced every tick - a free-running
    /// lens clock, the time source an animated sprite cycles its frames on.
    elapsed_us: u64 = 0,
    /// tick()'s working and output storage, sized once at activation so
    /// the per-frame path allocates nothing: timer snapshot, per-param
    /// touch flags, and room for every parameter-bound effect at once.
    tick_timer_values: []trigger.TimerValue,
    tick_counter_values: []trigger.CounterValue,
    tick_touched: []bool,
    tick_applied: []AppliedEffect,
    /// Bundle-relative paths of sounds a play_sound trigger fired this tick;
    /// the host drains them each frame. Sized to the trigger count, so the
    /// frame path never allocates.
    tick_sounds: [][]const u8,
    tick_sound_count: usize = 0,
    /// Haptics a haptic trigger fired this tick; the host drains them each
    /// frame and buzzes the device. Sized to the trigger count, so the frame
    /// path never allocates.
    tick_haptics: []HapticEvent,
    tick_haptic_count: usize = 0,

    pub fn deinit(self: *Lens, g: *graph.Graph) void {
        for (self.nodes) |n| g.removeNode(n.graph_index);
        for (self.compiled_triggers) |*expr| expr.deinit();
        self.gpa.free(self.compiled_triggers);
        self.gpa.free(self.trigger_was_true);
        self.gpa.free(self.param_values);
        self.gpa.free(self.ramps);
        self.gpa.free(self.nodes);
        for (self.timer_names) |name| self.gpa.free(name);
        self.gpa.free(self.timer_names);
        self.gpa.free(self.timer_elapsed_us);
        self.gpa.free(self.tick_timer_values);
        for (self.counter_names) |name| self.gpa.free(name);
        self.gpa.free(self.counter_names);
        self.gpa.free(self.counter_values);
        self.gpa.free(self.tick_counter_values);
        self.logic_arena.deinit();
        self.gpa.free(self.tick_param_snapshot);
        self.gpa.free(self.tick_touched);
        self.gpa.free(self.tick_applied);
        self.gpa.free(self.tick_sounds);
        self.gpa.free(self.tick_haptics);
        self.manifest.deinit();
        self.* = undefined;
    }

    /// Every currently-bound effect value across every spliced node, in
    /// splice order - what the caller applies to the beauty chain right
    /// after activation, before the first tick.
    pub fn currentEffects(self: *const Lens, gpa: std.mem.Allocator) std.mem.Allocator.Error![]AppliedEffect {
        var out: std.ArrayList(AppliedEffect) = .empty;
        errdefer out.deinit(gpa);
        for (self.nodes) |node| try self.collectNodeEffects(gpa, &out, node);
        return out.toOwnedSlice(gpa);
    }

    /// Every shader.pass node this lens spliced, in the graph's real
    /// execution order - the order a chain of passes must draw in so
    /// each one sees the previous stage's output, not just the order
    /// they happened to be declared in the manifest. g must be the same
    /// graph this lens was activated into.
    pub fn shaderPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]ShaderPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(ShaderPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .shader_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .shader_stem = node.asset_stem.?, .mask_channel = node.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every lut.pass node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes exactly, one node type
    /// over.
    pub fn lutPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]LutPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(LutPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .lut_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .lut_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every blend.pass node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes/lutPassNodes exactly,
    /// one more node type over.
    pub fn blendPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]BlendPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(BlendPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .blend_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .background_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every grade.pass node this lens spliced, in execution order, each
    /// carrying its parametric grade - mirrors the other per-kind accessors.
    pub fn gradePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]GradePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(GradePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .grade_pass) continue;
            const gr = node.grade orelse manifest.GradeField{};
            const hue_rad: f32 = gr.hue * (std.math.pi / 180.0);
            try out.append(gpa, .{ .graph_index = node.graph_index, .grade = .{
                gr.exposure, gr.contrast, gr.saturation, gr.temperature,
                gr.brightness, hue_rad,   gr.tint,       gr.grayscale,
                gr.invert,    gr.posterize, 0,           0,
            } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every bloom.pass node this lens spliced, in execution order, each
    /// carrying its glow params - mirrors gradePassNodes.
    pub fn bloomPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]BloomPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(BloomPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .bloom_pass) continue;
            const bl = node.bloom orelse manifest.BloomField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .bloom = .{ bl.threshold, bl.intensity, 0, 0 } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every dof.pass node this lens spliced, in execution order, each
    /// carrying its focus plane and blur strength.
    pub fn dofPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]DofPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(DofPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .dof_pass) continue;
            const d = node.dof orelse manifest.DofField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .focus = d.focus, .strength = d.strength });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every fog.pass node this lens spliced, in execution order, each
    /// carrying its fog color and density.
    pub fn fogPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]FogPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(FogPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .fog_pass) continue;
            const f = node.fog orelse manifest.FogField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .color = .{ f.r, f.g, f.b }, .density = f.density });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every outline.pass node this lens spliced, in execution order, each
    /// carrying its line color and depth threshold.
    pub fn outlinePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]OutlinePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(OutlinePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .outline_pass) continue;
            const o = node.outline orelse manifest.OutlineField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .color = .{ o.r, o.g, o.b }, .threshold = o.threshold, .mask_channel = o.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every occluder.pass node this lens spliced, in execution order, each
    /// carrying its silhouette expand and edge softness and the head channel.
    pub fn occluderPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]OccluderPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(OccluderPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .occluder_pass) continue;
            const o = node.occluder orelse manifest.OccluderField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ o.expand, o.softness }, .mask_channel = o.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every cutout.pass node this lens spliced, in execution order, each
    /// carrying its background color, edge softness, and face-matte channel.
    pub fn cutoutPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]CutoutPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(CutoutPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .cutout_pass) continue;
            const cf = node.cutout orelse manifest.CutoutField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ cf.r, cf.g, cf.b, cf.softness }, .mask_channel = cf.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every tint.pass node this lens spliced, in execution order, each
    /// carrying its color, opacity, and mask channel.
    pub fn tintPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]TintPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(TintPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .tint_pass) continue;
            const tf = node.tint orelse manifest.TintField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .color = .{ tf.r, tf.g, tf.b }, .opacity = tf.opacity, .mask_channel = tf.mask_channel, .from_reference = tf.from_reference, .blend = @intFromEnum(tf.blend), .finish = @intFromEnum(tf.finish) });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every smooth.pass node this lens spliced, in execution order, each
    /// carrying its retouch amount and mask channel.
    pub fn smoothPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]SmoothPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(SmoothPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .smooth_pass) continue;
            const sf = node.smooth orelse manifest.SmoothField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .amount = sf.amount, .mask_channel = sf.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every retouch.pass node this lens spliced, in execution order, each
    /// carrying its packed filter (mode index then amount) and mask channel.
    pub fn retouchPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]RetouchPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(RetouchPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .retouch_pass) continue;
            const rf = node.retouch orelse manifest.RetouchField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ @floatFromInt(@intFromEnum(rf.mode)), rf.amount }, .mask_channel = rf.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every matte.refine node this lens spliced, in execution order, each
    /// carrying its guided-filter parameters and the mask channel it refines.
    pub fn matteRefinePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]MattePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(MattePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .matte_refine) continue;
            const mf = node.matte orelse manifest.MatteField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ mf.radius, mf.sensitivity, mf.strength }, .mask_channel = mf.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every matte.hair source this lens spliced, in execution order, each
    /// carrying the guided-filter parameters it refines the coarse hair class
    /// into the hair_matte channel with.
    pub fn hairMattePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]HairMattePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(HairMattePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .matte_hair) continue;
            const hf = node.hair_matte orelse manifest.HairMatteField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ hf.radius, hf.sensitivity, hf.strength } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every stylize.pass node this lens spliced, in execution order, each
    /// carrying its artistic filter packed for u_stylize (mode index, then
    /// strength, threshold, and quantization levels).
    pub fn stylizePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]StylizePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(StylizePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .stylize_pass) continue;
            const yf = node.stylize orelse manifest.StylizeField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ @floatFromInt(@intFromEnum(yf.mode)), yf.strength, yf.threshold, yf.levels } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every edge.pass node this lens spliced, in execution order, each
    /// carrying its detector packed as (mode, low, high, blur_radius,
    /// strength, invert) - mode 0 sobel, mode 1 canny.
    pub fn edgePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]EdgePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(EdgePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .edge_pass) continue;
            const ef = node.edge orelse manifest.EdgeField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = .{ @floatFromInt(@intFromEnum(ef.mode)), ef.low_threshold, ef.high_threshold, ef.blur_radius, ef.strength, if (ef.invert) 1 else 0 } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every warp.pass node this lens spliced, in execution order, each
    /// carrying its distortion flat-packed for the shader: the ten-float
    /// header, then the liquify points as (x, y, dx, dy), then their radii.
    pub fn warpPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]WarpPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(WarpPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .warp_pass) continue;
            const wf = node.warp orelse manifest.WarpField{};
            var params = [_]f32{0} ** manifest.warp_params_len;
            params[0] = @floatFromInt(@intFromEnum(wf.mode));
            params[1] = wf.center_x;
            params[2] = wf.center_y;
            params[3] = wf.radius;
            params[4] = wf.strength;
            params[5] = wf.refractive_index;
            params[6] = if (wf.aspect_auto) 1 else 0;
            params[7] = if (wf.symmetry) 1 else 0;
            params[8] = wf.symmetry_x;
            params[9] = @floatFromInt(wf.point_count);
            var i: usize = 0;
            while (i < wf.point_count) : (i += 1) {
                const pt = wf.points[i];
                params[10 + i * 4 + 0] = pt.x;
                params[10 + i * 4 + 1] = pt.y;
                params[10 + i * 4 + 2] = pt.dx;
                params[10 + i * 4 + 3] = pt.dy;
                params[10 + manifest.warp_point_max * 4 + i] = pt.radius;
            }
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = params, .mask_channel = wf.mask_channel });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every reshape.bank node this lens spliced, in execution order, each
    /// carrying its sixty-six per-region sculpt amounts flattened in the
    /// ReshapeField declaration order.
    pub fn reshapePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]ReshapePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(ReshapePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .reshape_bank) continue;
            const rf = node.reshape orelse manifest.ReshapeField{};
            var params: [66]f32 = undefined;
            inline for (std.meta.fields(manifest.ReshapeField), 0..) |f, i| {
                params[i] = @field(rf, f.name);
            }
            try out.append(gpa, .{ .graph_index = node.graph_index, .params = params });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every trail.pass node this lens spliced, in execution order, each
    /// carrying its motion-trail echo amount.
    pub fn trailPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]TrailPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(TrailPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .trail_pass) continue;
            const tr = node.trail orelse manifest.TrailField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .amount = tr.amount });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every ssr.pass node this lens spliced, in execution order, each
    /// carrying its reflection strength and floor plane.
    pub fn ssrPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]SsrPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(SsrPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .ssr_pass) continue;
            const sr = node.ssr orelse manifest.SsrField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .strength = sr.strength, .plane = sr.plane });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every env.pass node this lens spliced, in execution order, each
    /// carrying its sky gradient colors and intensity.
    pub fn envPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]EnvPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(EnvPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .env_pass) continue;
            const ev = node.env orelse manifest.EnvField{};
            try out.append(gpa, .{
                .graph_index = node.graph_index,
                .top = .{ ev.top_r, ev.top_g, ev.top_b },
                .bottom = .{ ev.bottom_r, ev.bottom_g, ev.bottom_b },
                .intensity = ev.intensity,
                .image_stem = node.asset_stem,
            });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every model.gltf node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes/lutPassNodes/
    /// blendPassNodes exactly, one more node type over.
    pub fn modelNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]ModelNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(ModelNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .model_gltf) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .model_stem = node.asset_stem.?, .node_id = node.asset_stem.?, .face_anchor = node.face_anchor, .retarget = node.retarget, .talk = node.talk, .body_anchor = node.body_anchor, .skeleton_anchor = node.skeleton_anchor, .world_anchor = node.world_anchor, .physics = node.physics, .cloth = node.cloth, .balloon = node.balloon, .hair = node.hair, .particles = node.particles, .control = node.control });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every mesh.face node this lens spliced, in execution order -
    /// mirrors the other per-kind accessors exactly.
    pub fn meshFaceNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]MeshFaceNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(MeshFaceNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .mesh_face) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .texture_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every mesh.lashes node this lens spliced, in execution order, each
    /// carrying its lash strip's colour, length, and curl - mirrors the other
    /// per-kind accessors.
    pub fn lashNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]LashNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(LashNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .mesh_lashes) continue;
            const lf = node.lashes orelse manifest.LashField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .color = .{ lf.r, lf.g, lf.b, lf.opacity }, .length = lf.length, .curl = lf.curl });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every paint.face node this lens spliced, in execution order, each
    /// carrying its texture stem, face region, opacity, and blend - mirrors
    /// the other per-kind accessors.
    pub fn paintFaceNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]PaintFaceNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(PaintFaceNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .paint_face) continue;
            const pf = node.paint orelse manifest.PaintField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .texture_stem = node.asset_stem.?, .mask_channel = pf.mask_channel, .opacity = pf.opacity, .blend = @intFromEnum(pf.blend) });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every face.swap node this lens spliced, in execution order, each carrying
    /// its donor stem, optional region, opacity, and seam feather - mirrors the
    /// other per-kind accessors.
    pub fn faceSwapNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]FaceSwapNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(FaceSwapNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .face_swap) continue;
            const sf = node.swap orelse manifest.SwapField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .donor_stem = node.asset_stem.?, .mask_channel = sf.mask_channel, .opacity = sf.opacity, .feather = sf.feather });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every sprite.2d node this lens spliced, in execution order, each
    /// carrying its image stem, screen rect, and opacity - mirrors the
    /// other per-kind accessors.
    pub fn spriteNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]SpriteNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(SpriteNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .sprite_2d) continue;
            const sp = node.sprite orelse manifest.SpriteField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .image_stem = node.asset_stem.?, .rect = .{ sp.x, sp.y, sp.w, sp.h }, .opacity = sp.opacity, .opacity_param = sp.opacity_param, .x_param = sp.x_param, .y_param = sp.y_param, .w_param = sp.w_param, .h_param = sp.h_param, .frames = sp.frames, .fps = sp.fps, .interaction = sp.interaction, .mask_channel = sp.mask_channel, .mask_over = sp.mask_mode == .over, .mask_strength = sp.mask_strength, .mask_strength_param = sp.mask_strength_param });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every splat.cloud node this lens spliced, in execution order, each
    /// carrying the model that lifts the frame to a point cloud and the
    /// billboard size and color it draws with.
    pub fn splatNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]SplatNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(SplatNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .splat_cloud) continue;
            const sf = node.splat orelse continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .model = sf.model, .point = sf.point, .color = .{ sf.r, sf.g, sf.b }, .mesh = sf.draw == .mesh, .selfie = sf.source == .selfie, .colored = sf.colored });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every text.2d node this lens spliced, in execution order, each
    /// carrying its string, rect, opacity, and color - the caller
    /// rasterizes the string and draws it like a sprite.
    pub fn textNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]TextNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(TextNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .text_2d) continue;
            const tf = node.text orelse manifest.TextField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .content = tf.content, .rect = .{ tf.x, tf.y, tf.w, tf.h }, .opacity = tf.opacity, .color = .{ tf.r, tf.g, tf.b }, .opacity_param = tf.opacity_param, .gradient = tf.gradient, .shadow = tf.shadow, .stroke = tf.stroke, .depth = tf.depth });
        }
        return out.toOwnedSlice(gpa);
    }

    pub fn videoNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]VideoNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(VideoNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .video_texture) continue;
            const vf = node.video orelse continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .source = vf.source, .rect = .{ vf.x, vf.y, vf.w, vf.h }, .opacity = vf.opacity, .fps = vf.fps, .loop = vf.loop });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every shader.pass, lut.pass, blend.pass, and model.gltf node
    /// this lens spliced, in one real execution-order sequence - the
    /// actual draw order for a chain that mixes any of the four kinds,
    /// which the per-kind accessors alone cannot express since each
    /// only ever sees its own kind.
    pub fn compositePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]CompositePass {
        const order = try g.executionOrder();
        var out: std.ArrayList(CompositePass) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            const kind: PassKind = switch (node.node_type) {
                .shader_pass => .shader,
                .lut_pass => .lut,
                .blend_pass => .blend,
                .blur_pass => .blur,
                .grade_pass => .grade,
                .bloom_pass => .bloom,
                .dof_pass => .dof,
                .fog_pass => .fog,
                .outline_pass => .outline,
                .occluder_pass => .occluder,
                .cutout_pass => .cutout,
                .tint_pass => .tint,
                .smooth_pass => .smooth,
                .retouch_pass => .retouch,
                .matte_refine => .matte,
                .matte_hair => .hair_matte,
                .stylize_pass => .stylize,
                .edge_pass => .edge,
                .warp_pass => .warp,
                .reshape_bank => .reshape,
                .trail_pass => .trail,
                .ssr_pass => .ssr,
                .env_pass => .env,
                .model_gltf => .model,
                .mesh_face => .mesh,
                .mesh_lashes => .lashes,
                .paint_face => .paint,
                .face_swap => .face_swap,
                .draw_board => .draw_board,
                .sprite_2d, .text_2d, .video_texture => .sprite,
                .splat_cloud => .splat,
                else => continue,
            };
            try out.append(gpa, .{ .graph_index = node.graph_index, .kind = kind });
        }
        return out.toOwnedSlice(gpa);
    }

    /// The first layout.composite node's field, if the lens has one, so the head
    /// composite can take its arrangement and camera blend from the lens rather
    /// than a host set_layout call. A layout.composite node draws nothing itself.
    pub fn layoutComposite(self: *const Lens) ?manifest.LayoutField {
        for (self.nodes) |node| {
            if (node.node_type == .layout_composite) return node.layout;
        }
        return null;
    }

    /// Current playback position for a model.gltf node, microseconds
    /// since its play_animation trigger last fired - null if it never
    /// has. The caller samples the loaded animation clip at this time;
    /// this module holds no clip data of its own.
    pub fn modelElapsedUs(self: *const Lens, graph_index: graph.NodeIndex) ?u64 {
        const node = self.findNode(graph_index) orelse return null;
        return node.model_elapsed_us;
    }

    /// Microseconds since this lens activated, advanced every tick.
    pub fn elapsedUs(self: *const Lens) u64 {
        return self.elapsed_us;
    }

    /// The blend weight the model.gltf node at graph_index binds to its
    /// clip at clip_index: the live value of the bound parameter, 0 for a
    /// clip past the bound list. Null when the node binds no weights, so
    /// the caller falls back to playing the first clip at full weight.
    pub fn clipWeight(self: *const Lens, graph_index: graph.NodeIndex, clip_index: usize) ?f32 {
        const node = self.findNode(graph_index) orelse return null;
        if (node.clip_weights.len == 0) return null;
        if (clip_index >= node.clip_weights.len) return 0;
        return self.paramValue(node.clip_weights[clip_index]) orelse 0;
    }

    /// Whether the model.gltf node at graph_index binds any clip weights,
    /// so the caller knows to blend rather than take the single-clip path.
    pub fn bindsClipWeights(self: *const Lens, graph_index: graph.NodeIndex) bool {
        const node = self.findNode(graph_index) orelse return false;
        return node.clip_weights.len > 0;
    }

    /// The blend weight the model.gltf node at graph_index binds to its
    /// morph target at target_index: the bound parameter's live value, 0
    /// for a target past the bound list or when the node binds none.
    pub fn morphWeight(self: *const Lens, graph_index: graph.NodeIndex, target_index: usize) f32 {
        const node = self.findNode(graph_index) orelse return 0;
        if (target_index >= node.morph_weights.len) return 0;
        return self.paramValue(node.morph_weights[target_index]) orelse 0;
    }

    /// Whether the model.gltf node at graph_index binds any morph weights,
    /// so the caller knows to deform the mesh this frame.
    pub fn bindsMorphWeights(self: *const Lens, graph_index: graph.NodeIndex) bool {
        const node = self.findNode(graph_index) orelse return false;
        return node.morph_weights.len > 0;
    }

    /// The inline source of this lens's script node, or null if it has none.
    /// The host runs it each tick to drive parameters.
    pub fn scriptSource(self: *const Lens) ?[]const u8 {
        for (self.manifest.nodes) |node| {
            if (node.script) |src| return src;
        }
        return null;
    }

    /// Sets a live parameter by name, clamped to its declared range. Silent
    /// no-op for an unknown name, the same tolerance a trigger action takes.
    pub fn setParam(self: *Lens, name: []const u8, value: f32) void {
        const i = paramIndex(self, name) orelse return;
        self.param_values[i] = clampToParam(self.manifest.parameters[i], value);
    }

    /// Reads a live parameter by name, or null if there is no such name.
    pub fn paramValue(self: *const Lens, name: []const u8) ?f32 {
        const i = paramIndex(self, name) orelse return null;
        return self.param_values[i];
    }

    /// The bundle-relative sound paths a play_sound trigger fired on the last
    /// tick, for the host to start on its mixer.
    pub fn firedSounds(self: *const Lens) []const []const u8 {
        return self.tick_sounds[0..self.tick_sound_count];
    }

    /// The haptics a haptic trigger fired on the last tick, for the host to
    /// buzz the device with.
    pub fn firedHaptics(self: *const Lens) []const HapticEvent {
        return self.tick_haptics[0..self.tick_haptic_count];
    }

    /// Whether this lens spliced any beauty.* node - what gates whether
    /// the live preview needs the GPU beauty compositing bridge running
    /// at all. A lens with no beauty node still lets a session enable
    /// beauty (currentEffects then applies nothing, all identity values),
    /// but compositing every frame through gpupixel for a chain that can
    /// never produce a visible difference would be pure waste.
    pub fn hasBeautyNodes(self: *const Lens) bool {
        for (self.nodes) |node| {
            switch (node.node_type) {
                .beauty_face, .beauty_reshape, .beauty_lipstick, .beauty_blusher => return true,
                else => {},
            }
        }
        return false;
    }

    fn findNode(self: *const Lens, graph_index: graph.NodeIndex) ?LensNode {
        for (self.nodes) |node| {
            if (node.graph_index == graph_index) return node;
        }
        return null;
    }

    fn collectNodeEffects(self: *const Lens, gpa: std.mem.Allocator, out: *std.ArrayList(AppliedEffect), node: LensNode) !void {
        for (node.bindings, 0..) |binding, i| {
            const source = binding orelse continue;
            const value = switch (source) {
                .literal => |v| v,
                .parameter => |idx| self.param_values[idx],
            };
            try out.append(gpa, .{ .effect = @enumFromInt(i), .value = value });
        }
    }
};

/// Splices lens_manifest's node subgraph into g, wired to camera_node
/// wherever a node's input names the implicit "camera" source. Every
/// trigger's `when` source compiles here too - the validator
/// already proved a shipped bundle's triggers compile clean, so a
/// compile failure at activation is a caller bug (a hand-built manifest
/// that skipped validation), not a normal-operation error path.
pub fn activate(gpa: std.mem.Allocator, g: *graph.Graph, camera_node: graph.NodeIndex, lens_manifest: manifest.Manifest) ActivateError!Lens {
    const param_values = try gpa.alloc(f32, lens_manifest.parameters.len);
    errdefer gpa.free(param_values);
    for (lens_manifest.parameters, 0..) |p, i| param_values[i] = switch (p.default) {
        .float => |v| v,
        .bool => |v| if (v) 1 else 0,
        .int => |v| @floatFromInt(v),
        .color => 0,
    };

    const ramps = try gpa.alloc(?animation.Ramp, lens_manifest.parameters.len);
    errdefer gpa.free(ramps);
    @memset(ramps, null);

    const param_names = try gpa.alloc([]const u8, lens_manifest.parameters.len);
    defer gpa.free(param_names);
    for (lens_manifest.parameters, 0..) |p, i| param_names[i] = p.name;

    const compiled_triggers = try gpa.alloc(trigger.Expression, lens_manifest.triggers.len);
    errdefer gpa.free(compiled_triggers);
    var compiled_count: usize = 0;
    errdefer for (compiled_triggers[0..compiled_count]) |*expr| expr.deinit();

    for (lens_manifest.triggers) |lens_trigger| {
        var diag_arena = std.heap.ArenaAllocator.init(gpa);
        defer diag_arena.deinit();
        var compile_err: ?trigger.CompileError = null;
        const expr = trigger.compile(gpa, diag_arena.allocator(), lens_trigger.when_source, param_names, &compile_err) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        compiled_triggers[compiled_count] = expr orelse return error.UnknownParameter;
        compiled_count += 1;
    }

    const trigger_was_true = try gpa.alloc(bool, lens_manifest.triggers.len);
    errdefer gpa.free(trigger_was_true);
    @memset(trigger_was_true, false);

    // Script nodes are skipped below (they drive parameters, they do not
    // splice), so size the node array to the composite nodes only.
    var composite_count: usize = 0;
    for (lens_manifest.nodes) |node| {
        if (!isBehaviorNode(node.type)) composite_count += 1;
    }
    const nodes = try gpa.alloc(LensNode, composite_count);
    errdefer gpa.free(nodes);
    var spliced_count: usize = 0;
    errdefer for (nodes[0..spliced_count]) |n| g.removeNode(n.graph_index);

    var id_to_index = std.StringHashMap(graph.NodeIndex).init(gpa);
    defer id_to_index.deinit();

    // First pass: splice every composite node and register its id, so an
    // input can name a node declared later in the manifest. Connections
    // and bindings follow in the second pass once every id is known; the
    // errdefer owns the fresh node until the counted one takes over.
    for (lens_manifest.nodes) |node| {
        // A script node drives parameters each tick; it is not a composite
        // pass, so it never enters the graph. Its source is read separately.
        if (isBehaviorNode(node.type)) continue;
        const node_type = parseNodeType(node.type) orelse return error.UnsupportedNodeType;
        const graph_index = try g.addNode(.{
            .role = .transform,
            .inputs = &.{.{ .kind = .texture }},
            .outputs = &.{.{ .kind = .texture }},
        });
        errdefer g.removeNode(graph_index);
        nodes[spliced_count] = .{
            .graph_index = graph_index,
            .node_type = node_type,
            .asset_stem = switch (node_type) {
                .shader_pass, .lut_pass, .blend_pass, .env_pass, .model_gltf, .mesh_face, .paint_face, .face_swap, .sprite_2d => node.id,
                else => null,
            },
            .mask_channel = if (node_type == .shader_pass) node.mask_channel else null,
            .face_anchor = node_type == .model_gltf and node.face_anchor,
            .retarget = node_type == .model_gltf and node.retarget,
            .talk = node_type == .model_gltf and node.talk,
            .body_anchor = node_type == .model_gltf and node.body_anchor,
            .skeleton_anchor = node_type == .model_gltf and node.skeleton_anchor,
            .world_anchor = node_type == .model_gltf and node.world_anchor,
            .physics = if (node_type == .model_gltf) node.physics else null,
            .cloth = if (node_type == .model_gltf) node.cloth else null,
            .balloon = if (node_type == .model_gltf) node.balloon else null,
            .hair = if (node_type == .model_gltf) node.hair else null,
            .particles = if (node_type == .model_gltf) node.particles else null,
            .control = if (node_type == .model_gltf) node.control else null,
            .clip_weights = if (node_type == .model_gltf) node.clip_weights else &.{},
            .morph_weights = if (node_type == .model_gltf) node.morph_weights else &.{},
            .sprite = if (node_type == .sprite_2d) node.sprite else null,
            .text = if (node_type == .text_2d) node.text else null,
            .video = if (node_type == .video_texture) node.video else null,
            .splat = if (node_type == .splat_cloud) node.splat else null,
            .grade = if (node_type == .grade_pass) node.grade else null,
            .bloom = if (node_type == .bloom_pass) node.bloom else null,
            .dof = if (node_type == .dof_pass) node.dof else null,
            .fog = if (node_type == .fog_pass) node.fog else null,
            .outline = if (node_type == .outline_pass) node.outline else null,
            .occluder = if (node_type == .occluder_pass) node.occluder else null,
            .cutout = if (node_type == .cutout_pass) node.cutout else null,
            .tint = if (node_type == .tint_pass) node.tint else null,
            .smooth = if (node_type == .smooth_pass) node.smooth else null,
            .paint = if (node_type == .paint_face) node.paint else null,
            .swap = if (node_type == .face_swap) node.swap else null,
            .lashes = if (node_type == .mesh_lashes) node.lashes else null,
            .retouch = if (node_type == .retouch_pass) node.retouch else null,
            .matte = if (node_type == .matte_refine) node.matte else null,
            .hair_matte = if (node_type == .matte_hair) node.hair_matte else null,
            .stylize = if (node_type == .stylize_pass) node.stylize else null,
            .edge = if (node_type == .edge_pass) node.edge else null,
            .warp = if (node_type == .warp_pass) node.warp else null,
            .reshape = if (node_type == .reshape_bank) node.reshape else null,
            .trail = if (node_type == .trail_pass) node.trail else null,
            .ssr = if (node_type == .ssr_pass) node.ssr else null,
            .env = if (node_type == .env_pass) node.env else null,
            .layout = if (node_type == .layout_composite) node.layout else null,
        };

        try id_to_index.put(node.id, graph_index);
        spliced_count += 1;
    }

    // Second pass: connect inputs and bind parameters. A failure here
    // (unknown id, cycle-closing edge, unknown parameter) unwinds through
    // the counted errdefer, which now covers every spliced node.
    var node_at: usize = 0;
    for (lens_manifest.nodes) |node| {
        if (isBehaviorNode(node.type)) continue;
        const graph_index = nodes[node_at].graph_index;

        for (node.inputs) |input| {
            const source_index = if (std.mem.eql(u8, input.source, "camera"))
                camera_node
            else
                id_to_index.get(input.source) orelse return error.UnknownNodeId;
            try g.connect(source_index, 0, graph_index, 0);
        }

        const slots = paramSlotsFor(nodes[node_at].node_type);
        for (node.params) |p| {
            for (slots) |slot| {
                if (!std.mem.eql(u8, p.name, slot.name)) continue;
                nodes[node_at].bindings[@intFromEnum(slot.effect)] = switch (p.binding) {
                    .literal_float => |v| .{ .literal = v },
                    .literal_bool => |v| .{ .literal = if (v) 1 else 0 },
                    .literal_int => |v| .{ .literal = @floatFromInt(v) },
                    .param_ref => |name| blk: {
                        for (lens_manifest.parameters, 0..) |param, i| {
                            if (std.mem.eql(u8, param.name, name)) break :blk .{ .parameter = @intCast(i) };
                        }
                        return error.UnknownParameter;
                    },
                };
            }
        }
        node_at += 1;
    }

    var timer_names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (timer_names.items) |name| gpa.free(name);
        timer_names.deinit(gpa);
    }
    for (compiled_triggers) |*expr| try collectTimerNames(gpa, expr.root, &timer_names);
    const timer_elapsed_us = try gpa.alloc(u64, timer_names.items.len);
    errdefer gpa.free(timer_elapsed_us);
    @memset(timer_elapsed_us, 0);

    const tick_timer_values = try gpa.alloc(trigger.TimerValue, timer_names.items.len);
    errdefer gpa.free(tick_timer_values);

    var counter_names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (counter_names.items) |name| gpa.free(name);
        counter_names.deinit(gpa);
    }
    for (compiled_triggers) |*expr| try collectCounterNames(gpa, expr.root, &counter_names);
    for (lens_manifest.triggers) |trig| {
        switch (trig.action.kind) {
            .increment_counter, .reset_counter, .set_counter => try addCounterName(gpa, &counter_names, trig.action.target),
            else => {},
        }
    }
    const counter_values = try gpa.alloc(f64, counter_names.items.len);
    errdefer gpa.free(counter_values);
    @memset(counter_values, 0);
    const tick_counter_values = try gpa.alloc(trigger.CounterValue, counter_names.items.len);
    errdefer gpa.free(tick_counter_values);

    const tick_touched = try gpa.alloc(bool, param_values.len);
    errdefer gpa.free(tick_touched);
    var bound_count: usize = 0;
    for (nodes) |node| {
        for (node.bindings) |binding| {
            const source = binding orelse continue;
            if (source == .parameter) bound_count += 1;
        }
    }
    const tick_applied = try gpa.alloc(AppliedEffect, bound_count);
    errdefer gpa.free(tick_applied);
    const tick_sounds = try gpa.alloc([]const u8, lens_manifest.triggers.len);
    errdefer gpa.free(tick_sounds);
    const tick_haptics = try gpa.alloc(HapticEvent, lens_manifest.triggers.len);
    errdefer gpa.free(tick_haptics);
    const tick_param_snapshot = try gpa.alloc(f64, param_values.len);
    errdefer gpa.free(tick_param_snapshot);

    var logic_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer logic_arena.deinit();
    var logic_diag = std.heap.ArenaAllocator.init(gpa);
    defer logic_diag.deinit();
    const logic_graphs = try compileLogicGraphs(logic_arena.allocator(), logic_diag.allocator(), lens_manifest, param_names);

    return .{
        .gpa = gpa,
        .manifest = lens_manifest,
        .compiled_triggers = compiled_triggers,
        .trigger_was_true = trigger_was_true,
        .param_values = param_values,
        .ramps = ramps,
        .nodes = nodes,
        .timer_names = try timer_names.toOwnedSlice(gpa),
        .timer_elapsed_us = timer_elapsed_us,
        .tick_timer_values = tick_timer_values,
        .counter_names = try counter_names.toOwnedSlice(gpa),
        .counter_values = counter_values,
        .tick_counter_values = tick_counter_values,
        .tick_touched = tick_touched,
        .tick_applied = tick_applied,
        .tick_sounds = tick_sounds,
        .tick_haptics = tick_haptics,
        .logic_arena = logic_arena,
        .logic_graphs = logic_graphs,
        .tick_param_snapshot = tick_param_snapshot,
    };
}

/// Resolves a logic op name to its enum, accepting the friendly aliases const,
/// and, or and not for the reserved-word ops.
fn logicOp(name: []const u8) ?logic.Op {
    if (std.mem.eql(u8, name, "const")) return .constant;
    if (std.mem.eql(u8, name, "and")) return .logic_and;
    if (std.mem.eql(u8, name, "or")) return .logic_or;
    if (std.mem.eql(u8, name, "not")) return .logic_not;
    return std.meta.stringToEnum(logic.Op, name);
}

/// Resolves a node-id reference among the nodes before `before`, so a wired
/// input reads an already-evaluated node; an empty or unknown ref is a literal.
fn resolveLogicRef(specs: []const manifest.LogicNodeSpec, ref: []const u8, before: usize) i32 {
    if (ref.len == 0) return -1;
    for (specs[0..before], 0..) |n, j| {
        if (std.mem.eql(u8, n.id, ref)) return @intCast(j);
    }
    return -1;
}

/// Compiles every logic.graph node in the manifest into an evaluatable graph,
/// resolving node refs to indices, signal leaves through the trigger parser,
/// and param leaves to parameter indices; all storage lives in arena.
fn compileLogicGraphs(arena: std.mem.Allocator, diag_arena: std.mem.Allocator, lens_manifest: manifest.Manifest, param_names: []const []const u8) error{OutOfMemory}![]CompiledLogicGraph {
    var out: std.ArrayList(CompiledLogicGraph) = .empty;
    for (lens_manifest.nodes) |node| {
        const spec = node.logic_graph orelse continue;
        const nodes = try arena.alloc(logic.Node, spec.nodes.len);
        for (spec.nodes, 0..) |ns, i| {
            var ln: logic.Node = .{ .op = logicOp(ns.op) orelse .constant };
            ln.a = resolveLogicRef(spec.nodes, ns.a_ref, i);
            ln.a_lit = ns.a_lit;
            ln.b = resolveLogicRef(spec.nodes, ns.b_ref, i);
            ln.b_lit = ns.b_lit;
            ln.c = resolveLogicRef(spec.nodes, ns.c_ref, i);
            ln.c_lit = ns.c_lit;
            ln.constant = ns.constant;
            if (ln.op == .signal and ns.signal_source.len > 0) {
                var err: ?trigger.CompileError = null;
                if (try trigger.compileSignal(arena, diag_arena, ns.signal_source, param_names, &err)) |sig| ln.signal = sig;
            }
            if (ln.op == .param) {
                for (param_names, 0..) |pn, pi| {
                    if (std.mem.eql(u8, pn, ns.param_name)) {
                        ln.param_index = @intCast(pi);
                        break;
                    }
                }
            }
            nodes[i] = ln;
        }
        var output: usize = if (spec.nodes.len > 0) spec.nodes.len - 1 else 0;
        for (spec.nodes, 0..) |ns, j| {
            if (std.mem.eql(u8, ns.id, spec.output_id)) output = j;
        }
        try out.append(arena, .{
            .graph = .{ .nodes = nodes, .output = output },
            .output_param = spec.output_param,
            .scratch = try arena.alloc(f32, spec.nodes.len),
        });
    }
    return out.toOwnedSlice(arena);
}

/// Collects every distinct timer('name') a compiled trigger tree
/// references, deduped, each name individually owned by the caller -
/// see Lens.timer_names for why these are duped rather than borrowed
/// from the trigger's own compile-time arena.
fn collectTimerNames(gpa: std.mem.Allocator, node: *const trigger.Node, names: *std.ArrayList([]u8)) std.mem.Allocator.Error!void {
    switch (node.*) {
        .signal_bool => {},
        .compare => |c| {
            if (c.signal.kind != .timer) return;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, c.signal.timer_name)) return;
            }
            try names.append(gpa, try gpa.dupe(u8, c.signal.timer_name));
        },
        .not => |inner| try collectTimerNames(gpa, inner, names),
        .and_, .or_ => |combine| {
            try collectTimerNames(gpa, combine.lhs, names);
            try collectTimerNames(gpa, combine.rhs, names);
        },
    }
}

/// Adds a counter name to the deduped set, each individually owned, skipping an
/// empty name so an action with no target adds nothing.
fn addCounterName(gpa: std.mem.Allocator, names: *std.ArrayList([]u8), name: []const u8) std.mem.Allocator.Error!void {
    if (name.len == 0) return;
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(gpa, try gpa.dupe(u8, name));
}

/// Collects every counter('name') a compiled trigger tree reads, so a counter
/// referenced only in a condition still gets a slot; action targets are added
/// separately at construction.
fn collectCounterNames(gpa: std.mem.Allocator, node: *const trigger.Node, names: *std.ArrayList([]u8)) std.mem.Allocator.Error!void {
    switch (node.*) {
        .signal_bool => {},
        .compare => |c| {
            if (c.signal.kind == .counter) try addCounterName(gpa, names, c.signal.counter_name);
        },
        .not => |inner| try collectCounterNames(gpa, inner, names),
        .and_, .or_ => |combine| {
            try collectCounterNames(gpa, combine.lhs, names);
            try collectCounterNames(gpa, combine.rhs, names);
        },
    }
}

fn counterIndex(lens: *const Lens, name: []const u8) ?usize {
    for (lens.counter_names, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, name)) return i;
    }
    return null;
}

fn paramIndex(lens: *const Lens, name: []const u8) ?u16 {
    for (lens.manifest.parameters, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return @intCast(i);
    }
    return null;
}

fn timerIndex(lens: *const Lens, name: []const u8) ?usize {
    for (lens.timer_names, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, name)) return i;
    }
    return null;
}

fn clampToParam(p: manifest.Parameter, value: f32) f32 {
    return switch (p.type) {
        .float, .int => std.math.clamp(value, p.min, p.max),
        .bool, .color => value,
    };
}

/// Advances every named timer and in-flight ramp, fires every trigger
/// that just transitioned false-to-true, and returns the effect values
/// that changed as a result. Timers advance before triggers evaluate
/// (a timer is a continuously-running clock a trigger reads, so this
/// frame's trigger pass needs this frame's own elapsed time); ramps and
/// model playback advance after, so an action that starts one this
/// frame gets its first real advance now rather than sitting at its
/// starting value until the next tick. show/hide/swap_subgraph are
/// still not wired to anything (real remaining work, tracked
/// separately from this lens's own scope).
pub fn tick(lens: *Lens, real_dt_us: u32, signals: trigger.Signals) []const AppliedEffect {
    lens.elapsed_us +|= real_dt_us;
    for (lens.timer_elapsed_us) |*elapsed| elapsed.* += real_dt_us;
    for (lens.timer_names, lens.timer_elapsed_us, 0..) |name, elapsed_us, i| {
        lens.tick_timer_values[i] = .{ .name = name, .seconds = @as(f32, @floatFromInt(elapsed_us)) / 1_000_000.0 };
    }
    for (lens.counter_names, lens.counter_values, 0..) |name, value, i| {
        lens.tick_counter_values[i] = .{ .name = name, .value = value };
    }
    var live_signals = signals;
    live_signals.timers = lens.tick_timer_values;
    live_signals.counters = lens.tick_counter_values;

    const touched_params = lens.tick_touched;
    @memset(touched_params, false);
    lens.tick_sound_count = 0;
    lens.tick_haptic_count = 0;

    // The logic graphs run first, driving their output parameters off the live
    // signals, so a trigger or a script this tick reads their fresh values.
    if (lens.logic_graphs.len > 0) {
        for (lens.param_values, 0..) |v, i| lens.tick_param_snapshot[i] = v;
        live_signals.params = lens.tick_param_snapshot;
        for (lens.logic_graphs) |*lg| {
            const value = lg.graph.eval(lg.scratch, live_signals);
            if (paramIndex(lens, lg.output_param)) |idx| {
                lens.param_values[idx] = clampToParam(lens.manifest.parameters[idx], value);
                touched_params[idx] = true;
            }
        }
    }

    for (lens.compiled_triggers, 0..) |*expr, i| {
        const is_true = trigger.evaluate(expr.root, live_signals);
        defer lens.trigger_was_true[i] = is_true;
        if (is_true and !lens.trigger_was_true[i]) {
            applyAction(lens, lens.manifest.triggers[i].action, touched_params);
        }
    }

    for (lens.ramps, 0..) |*ramp, i| {
        if (ramp.*) |*r| {
            const value = r.advance(real_dt_us);
            lens.param_values[i] = value;
            touched_params[i] = true;
            if (r.done) ramp.* = null;
        }
    }

    for (lens.nodes) |*node| {
        if (node.model_elapsed_us) |*elapsed| elapsed.* += real_dt_us;
    }

    // Borrowed from the lens's own activation-sized storage, valid until
    // the next tick - the frame path allocates nothing.
    var count: usize = 0;
    for (lens.nodes) |node| {
        for (node.bindings, 0..) |binding, slot| {
            const source = binding orelse continue;
            if (source != .parameter or !touched_params[source.parameter]) continue;
            lens.tick_applied[count] = .{ .effect = @enumFromInt(slot), .value = lens.param_values[source.parameter] };
            count += 1;
        }
    }
    return lens.tick_applied[0..count];
}

fn applyAction(lens: *Lens, action: manifest.Action, touched_params: []bool) void {
    switch (action.kind) {
        .param_set => {
            const idx = paramIndex(lens, action.target) orelse return;
            lens.param_values[idx] = clampToParam(lens.manifest.parameters[idx], action.to);
            lens.ramps[idx] = null;
            touched_params[idx] = true;
        },
        .param_ramp => {
            const idx = paramIndex(lens, action.target) orelse return;
            const target = clampToParam(lens.manifest.parameters[idx], action.to);
            lens.ramps[idx] = switch (action.curve) {
                .spring => animation.Ramp.startSpring(lens.param_values[idx], target, action.stiffness, action.damping),
                // linear and every easing curve are time-based; the tags match
                // animation.Curve one to one, so map by name.
                else => |c| animation.Ramp.startEased(lens.param_values[idx], target, action.duration_ms, std.meta.stringToEnum(animation.Curve, @tagName(c)).?),
            };
        },
        .play_animation => {
            for (lens.nodes) |*node| {
                if (node.node_type != .model_gltf) continue;
                const stem = node.asset_stem orelse continue;
                if (!std.mem.eql(u8, stem, action.target)) continue;
                node.model_elapsed_us = 0;
            }
        },
        .reset_timer => {
            const idx = timerIndex(lens, action.target) orelse return;
            lens.timer_elapsed_us[idx] = 0;
        },
        .play_sound => {
            if (lens.tick_sound_count < lens.tick_sounds.len) {
                lens.tick_sounds[lens.tick_sound_count] = action.target;
                lens.tick_sound_count += 1;
            }
        },
        .increment_counter => {
            if (counterIndex(lens, action.target)) |idx| lens.counter_values[idx] += 1;
        },
        .reset_counter => {
            if (counterIndex(lens, action.target)) |idx| lens.counter_values[idx] = 0;
        },
        .set_counter => {
            if (counterIndex(lens, action.target)) |idx| lens.counter_values[idx] = action.to;
        },
        .haptic => {
            if (lens.tick_haptic_count < lens.tick_haptics.len) {
                lens.tick_haptics[lens.tick_haptic_count] = .{ .style = hapticStyleFromName(action.target), .intensity = action.to };
                lens.tick_haptic_count += 1;
            }
        },
        .show, .hide, .swap_subgraph => {},
    }
}

const t = std.testing;

const minimal_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.tick", "version": "1.0.0", "display_name": "Tick",
    \\  "engine_compat": ">=0.5", "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('jawOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

fn parseTestManifest(gpa: std.mem.Allocator, source: []const u8) !manifest.Manifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };
    return try manifest.parse(gpa, &diags, source) orelse error.TestUnexpectedResult;
}

test "activate splices one node into the graph, wired to the camera source" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.beauty_reshape, lens.nodes[0].node_type);
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    _ = try g.executionOrder();
}

test "a param bound to a node reports its default as the initial effect value" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 1), effects.len);
    try t.expectEqual(EffectSlot.thin_face, effects[0].effect);
    try t.expectEqual(@as(f32, 0.0), effects[0].value);
}

const clip_weight_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.mixer", "version": "1.0.0", "display_name": "Mixer",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [
    \\    {"name": "walk", "type": "float", "default": 1.0, "min": 0.0, "max": 1.0},
    \\    {"name": "run", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
    \\  "nodes": [
    \\    {"id": "body", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "clip_weights": ["walk", "run"]}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a model node reads its clip weights from the parameters it binds" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, clip_weight_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(NodeType.model_gltf, lens.nodes[0].node_type);
    const gi = lens.nodes[0].graph_index;
    try t.expect(lens.bindsClipWeights(gi));
    try t.expectEqual(@as(f32, 1.0), lens.clipWeight(gi, 0).?); // walk default
    try t.expectEqual(@as(f32, 0.0), lens.clipWeight(gi, 1).?); // run default
    try t.expectEqual(@as(f32, 0.0), lens.clipWeight(gi, 2).?); // a clip past the list weighs nothing

    lens.setParam("run", 0.75);
    try t.expectEqual(@as(f32, 0.75), lens.clipWeight(gi, 1).?);
}

const morph_weight_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.morph", "version": "1.0.0", "display_name": "Morph",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [
    \\    {"name": "smile", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0},
    \\    {"name": "blink", "type": "float", "default": 0.25, "min": 0.0, "max": 1.0}],
    \\  "nodes": [
    \\    {"id": "face", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "morph_weights": ["smile", "blink"]}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a model node reads its morph weights from the parameters it binds" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, morph_weight_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(NodeType.model_gltf, lens.nodes[0].node_type);
    const gi = lens.nodes[0].graph_index;
    try t.expect(lens.bindsMorphWeights(gi));
    try t.expectEqual(@as(f32, 0.0), lens.morphWeight(gi, 0)); // smile default
    try t.expectEqual(@as(f32, 0.25), lens.morphWeight(gi, 1)); // blink default
    try t.expectEqual(@as(f32, 0.0), lens.morphWeight(gi, 2)); // a target past the list weighs nothing

    lens.setParam("smile", 1.0);
    try t.expectEqual(@as(f32, 1.0), lens.morphWeight(gi, 0));
}

const sprite_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.sprite", "version": "1.0.0", "display_name": "Sprite",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}, "sprite": {"x": 0.2, "y": 0.3, "w": 0.4, "h": 0.5, "opacity": 0.6}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a sprite node surfaces its stem, rect, and opacity" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, sprite_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(NodeType.sprite_2d, lens.nodes[0].node_type);
    const sprites = try lens.spriteNodes(t.allocator, &g);
    defer t.allocator.free(sprites);
    try t.expectEqual(@as(usize, 1), sprites.len);
    try t.expectEqualStrings("badge", sprites[0].image_stem);
    try t.expectApproxEqAbs(@as(f32, 0.2), sprites[0].rect[0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), sprites[0].rect[3], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.6), sprites[0].opacity, 0.001);
}

const shader_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.shaderpass", "version": "1.0.0", "display_name": "Shader Pass",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a shader.pass node splices with no effect bindings and resolves its shader by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, shader_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.shader_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 1), passes.len);
    try t.expectEqualStrings("tint", passes[0].shader_stem);
    try t.expectEqual(lens.nodes[0].graph_index, passes[0].graph_index);
}

const shader_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.shaderchain", "version": "1.0.0", "display_name": "Shader Chain",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "warm", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "vignette", "type": "shader.pass", "inputs": {"frame": "warm"}, "params": {}},
    \\    {"id": "grain", "type": "shader.pass", "inputs": {"frame": "vignette"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "shaderPassNodes orders a multi-pass chain by real graph dependency, not declaration position" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, shader_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 3), passes.len);
    try t.expectEqualStrings("warm", passes[0].shader_stem);
    try t.expectEqualStrings("vignette", passes[1].shader_stem);
    try t.expectEqualStrings("grain", passes[2].shader_stem);
}

const forward_reference_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.forwardref", "version": "1.0.0", "display_name": "Forward Ref",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "vignette", "type": "shader.pass", "inputs": {"frame": "warm"}, "params": {}},
    \\    {"id": "warm", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a node may reference one declared later in the manifest" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    // vignette reads warm, which the manifest declares after it. The
    // two-pass activation registers every id before wiring inputs, so the
    // forward reference resolves and the chain orders warm then vignette.
    const lens_manifest = try parseTestManifest(t.allocator, forward_reference_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 2), passes.len);
    try t.expectEqualStrings("warm", passes[0].shader_stem);
    try t.expectEqualStrings("vignette", passes[1].shader_stem);
}

const lut_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.lutpass", "version": "1.0.0", "display_name": "LUT Pass",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a lut.pass node splices with no effect bindings and resolves its LUT by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, lut_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.lut_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 1), luts.len);
    try t.expectEqualStrings("warm-lut", luts[0].lut_stem);
    try t.expectEqual(lens.nodes[0].graph_index, luts[0].graph_index);

    // Neither accessor picks up the other node type's node.
    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 0), passes.len);
}

const blend_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.blendpass", "version": "1.0.0", "display_name": "Blend Pass",
    \\  "engine_compat": ">=0.5", "capabilities": ["segmentation"],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "beach", "type": "blend.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a blend.pass node splices with no effect bindings and resolves its background by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, blend_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.blend_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const blends = try lens.blendPassNodes(t.allocator, &g);
    defer t.allocator.free(blends);
    try t.expectEqual(@as(usize, 1), blends.len);
    try t.expectEqualStrings("beach", blends[0].background_stem);
    try t.expectEqual(lens.nodes[0].graph_index, blends[0].graph_index);

    // Neither of the other two accessors picks up this node type's node.
    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 0), passes.len);
    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 0), luts.len);
}

const mixed_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.mixedchain", "version": "1.0.0", "display_name": "Mixed Chain",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "tint"}, "params": {}},
    \\    {"id": "vignette", "type": "shader.pass", "inputs": {"frame": "warm-lut"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "shader.pass and lut.pass nodes interleave in one chain, each accessor seeing only its own kind in order" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, mixed_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 2), passes.len);
    try t.expectEqualStrings("tint", passes[0].shader_stem);
    try t.expectEqualStrings("vignette", passes[1].shader_stem);

    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 1), luts.len);
    try t.expectEqualStrings("warm-lut", luts[0].lut_stem);
}

test "compositePassNodes interleaves both kinds in one real draw-order sequence" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, mixed_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 3), chain.len);
    try t.expectEqual(NodeType.shader_pass, lens.nodes[0].node_type);
    try t.expectEqual(PassKind.shader, chain[0].kind);
    try t.expectEqual(PassKind.lut, chain[1].kind);
    try t.expectEqual(PassKind.shader, chain[2].kind);
    try t.expectEqual(lens.nodes[0].graph_index, chain[0].graph_index);
    try t.expectEqual(lens.nodes[1].graph_index, chain[1].graph_index);
    try t.expectEqual(lens.nodes[2].graph_index, chain[2].graph_index);
}

const draw_board_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.drawboard", "version": "1.0.0", "display_name": "Draw Board",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "sketch", "type": "draw.board", "inputs": {"frame": "tint"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a draw.board node becomes a draw_board pass in the chain" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, draw_board_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 2), chain.len);
    try t.expectEqual(PassKind.shader, chain[0].kind);
    try t.expectEqual(PassKind.draw_board, chain[1].kind);
}

const layout_composite_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.layoutcomposite", "version": "1.0.0", "display_name": "Layout",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "compose", "type": "layout.composite", "inputs": {"frame": "camera"}, "params": {}, "layout": {"arrangement": "overlay", "opacity": 0.5}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a layout.composite node drives the head layout, not the draw chain" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, layout_composite_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const lf = lens.layoutComposite() orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u8, 5), lf.arrangement); // overlay
    try t.expectApproxEqAbs(@as(f32, 0.5), lf.opacity, 1e-6);
    // It configures the head composite, so it is not a draw-chain pass.
    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 0), chain.len);
}

const three_way_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.threewaychain", "version": "1.0.0", "display_name": "Three Way Chain",
    \\  "engine_compat": ">=0.5", "capabilities": ["segmentation"],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "tint"}, "params": {}},
    \\    {"id": "beach", "type": "blend.pass", "inputs": {"frame": "warm-lut"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "compositePassNodes interleaves all three kinds in one real draw-order sequence" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, three_way_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 3), chain.len);
    try t.expectEqual(PassKind.shader, chain[0].kind);
    try t.expectEqual(PassKind.lut, chain[1].kind);
    try t.expectEqual(PassKind.blend, chain[2].kind);

    const blends = try lens.blendPassNodes(t.allocator, &g);
    defer t.allocator.free(blends);
    try t.expectEqual(@as(usize, 1), blends.len);
    try t.expectEqualStrings("beach", blends[0].background_stem);
}

test "a trigger firing on the rising edge starts a ramp that settles, does not refire while held, and rearms on the falling edge" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const face_mod = @import("face");
    var open_shapes: [face_mod.blendshape_count]f32 = @splat(0);
    open_shapes[face_mod.blendshapeIndex("jawOpen").?] = 0.9;
    const closed_shapes: [face_mod.blendshape_count]f32 = @splat(0);
    const signals_open = trigger.Signals{ .face_present = true, .blendshapes = &open_shapes };
    const signals_closed = trigger.Signals{ .face_present = true, .blendshapes = &closed_shapes };

    // Rising edge: the ramp starts and gets its first real advance
    // within this same tick, landing strictly between start and target.
    // Copy values out before the next tick - the returned slice borrows
    // the lens's own storage and the next call overwrites it.
    const first = tick(&lens, animation.fixed_step_us, signals_open);
    try t.expectEqual(@as(usize, 1), first.len);
    const first_value = first[0].value;
    try t.expect(first_value > 0.0 and first_value < 1.0);
    try t.expect(lens.trigger_was_true[0]);

    // Still true: does not refire - a level-triggered restart would
    // reset the ramp's progress back toward the start every frame.
    const second = tick(&lens, animation.fixed_step_us, signals_open);
    try t.expect(second[0].value > first_value);

    // Enough further ticks for the 200ms linear ramp to fully settle.
    var settle: usize = 0;
    while (settle < 40) : (settle += 1) {
        _ = tick(&lens, animation.fixed_step_us, signals_open);
    }
    try t.expectEqual(@as(f32, 1.0), lens.param_values[0]);
    try t.expect(lens.ramps[0] == null);

    // Falling edge resets the trigger's own state, ready to fire again.
    _ = tick(&lens, animation.fixed_step_us, signals_closed);
    try t.expect(!lens.trigger_was_true[0]);
}

test "a counter increments on an event, persists, and drives a trigger at its threshold" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const src =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "win", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [{"id": "s", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}}],
        \\ "triggers": [
        \\   {"when": "event('hit')", "action": {"kind": "increment_counter", "target": "score"}},
        \\   {"when": "counter('score') >= 1", "action": {"kind": "param_set", "target": "win", "to": 1.0}}]}
    ;
    const lens_manifest = try parseTestManifest(t.allocator, src);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    // The event steps the counter to one, which persists on the lens.
    const hit = [_][]const u8{"hit"};
    _ = tick(&lens, animation.fixed_step_us, .{ .events = &hit });
    try t.expectEqual(@as(usize, 1), lens.counter_names.len);
    try t.expectApproxEqAbs(@as(f64, 1.0), lens.counter_values[0], 1e-9);

    // The next tick sees the counter at its threshold and fires the trigger.
    _ = tick(&lens, animation.fixed_step_us, .{});
    try t.expectApproxEqAbs(@as(f32, 1.0), lens.paramValue("win").?, 1e-6);
}

test "a haptic trigger queues a styled buzz for the host to drain" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const src =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [{"id": "s", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}}],
        \\ "triggers": [{"when": "event('buzz')", "action": {"kind": "haptic", "target": "success", "to": 0.8}}]}
    ;
    const lens_manifest = try parseTestManifest(t.allocator, src);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const buzz = [_][]const u8{"buzz"};
    _ = tick(&lens, animation.fixed_step_us, .{ .events = &buzz });
    const fired = lens.firedHaptics();
    try t.expectEqual(@as(usize, 1), fired.len);
    try t.expectEqual(HapticStyle.success, fired[0].style);
    try t.expectApproxEqAbs(@as(f32, 0.8), fired[0].intensity, 1e-6);

    // The buzz is a one-tick pulse; a quiet tick clears it.
    _ = tick(&lens, animation.fixed_step_us, .{});
    try t.expectEqual(@as(usize, 0), lens.firedHaptics().len);
}

test "a logic graph drives a parameter from the signals each tick" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const src =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "intensity", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [{"id": "g", "type": "logic.graph", "params": {},
        \\   "graph": {"output_param": "intensity", "output": "clamped", "nodes": [
        \\     {"id": "px", "op": "signal", "signal": "pointer.x"},
        \\     {"id": "scaled", "op": "mul", "a": "px", "b": 2.0},
        \\     {"id": "clamped", "op": "clamp", "a": "scaled", "b": 0.0, "c": 1.0}]}}],
        \\ "triggers": []}
    ;
    const lens_manifest = try parseTestManifest(t.allocator, src);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    _ = tick(&lens, animation.fixed_step_us, .{ .pointer_x = 0.3 });
    try t.expectApproxEqAbs(@as(f32, 0.6), lens.paramValue("intensity").?, 1e-5);
    _ = tick(&lens, animation.fixed_step_us, .{ .pointer_x = 0.9 });
    try t.expectApproxEqAbs(@as(f32, 1.0), lens.paramValue("intensity").?, 1e-5);
}

test "an ml.infer node activates as a behavior node, outside the composite chain" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const src =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "score", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [{"id": "m", "type": "ml.infer", "params": {}, "ml": {"model": "model.tflite", "outputs": [{"param": "score"}]}}],
        \\ "triggers": []}
    ;
    const lens_manifest = try parseTestManifest(t.allocator, src);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);
    // The ml.infer node draws nothing, so no node joins the composite chain.
    try t.expectEqual(@as(usize, 0), lens.nodes.len);
}
