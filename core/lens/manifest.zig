//! manifest.json parsing and structural validation for a lens bundle.
//! A trigger's `when` expression is carried here as its raw source string
//! only; compiling it into the typed expression tree is trigger.zig's job,
//! since the grammar is its own closed production set. Every rejection
//! collects a diagnostic naming the JSON pointer it came from rather than
//! stopping at the first one, so a lens author sees every problem at once.

const std = @import("std");
const material = @import("material");

pub const max_manifest_bytes = 256 * 1024;
pub const max_json_depth = 32;
pub const max_parameters = 256;
pub const max_nodes = 128;
pub const max_triggers = 256;
pub const max_when_bytes = 1024;
/// A ramp holds its duration in microseconds (u32), so a millisecond
/// duration is bounded to keep ms*1000 inside that width (about 71 minutes).
pub const max_duration_ms: f64 = std.math.maxInt(u32) / 1000;

pub const Capability = enum {
    face,
    hands,
    segmentation,
    world,
    audio_level,
};

pub const ParamType = enum { float, bool, int, color };

pub const ParamValue = union(ParamType) {
    float: f32,
    bool: bool,
    int: i32,
    color: [4]f32,
};

pub const Parameter = struct {
    name: []const u8,
    type: ParamType,
    default: ParamValue,
    min: f32 = 0,
    max: f32 = 0,
};

pub const ParamBinding = union(enum) {
    literal_float: f32,
    literal_bool: bool,
    literal_int: i32,
    param_ref: []const u8,
};

pub const NodeInput = struct { name: []const u8, source: []const u8 };
pub const NodeParam = struct { name: []const u8, binding: ParamBinding };

/// The mask channels a shader.pass node may name: the subject-compat
/// person mask, then the multiclass model's own label order. Frozen
/// lens-format vocabulary; a running session without the class serves
/// the zero mask, so the effect draws nothing rather than everywhere.
pub const mask_channels = [_][]const u8{
    "person",  "background", "hair",    "body_skin", "face_skin",
    "clothes", "others",     "head",    "hand",      "lips",
    "eyes",    "brows",      "iris",    "teeth",     "contour",
    "highlight", "lash_line", "under_eye", "nasolabial", "sclera",
    "t_zone",  "hair_matte", "sky",     "ground",    "building",
};

/// mask_channels[1..model_class_end] are the selfie_multiclass model outputs
/// in label order; channels from model_class_end on derive another way, so
/// the model-class mapping must not reach them. head, hand and the face parts
/// ride the face and hand landmarks, not a segmentation model.
pub const model_class_end = 7;
/// hair is segmenter class 2; a coarse channel a matte.hair source lifts into
/// the strand-level hair_matte channel below.
pub const hair_channel = 2;
/// face_skin is segmenter class 4; a foundation tint keys its mask and a
/// reference photo can fill its color, so name the channel for both.
pub const skin_channel = 4;
pub const head_channel = 7;
pub const hand_channel = 8;
pub const lips_channel = 9;
pub const eyes_channel = 10;
pub const brows_channel = 11;
pub const iris_channel = 12;
pub const teeth_channel = 13;
/// Contour and highlight ride clustered face landmarks, not the segmenter:
/// contour darkens the cheekbone hollows, nose sides and jaw, highlight
/// lightens the cheekbone tops, brow bones, nose bridge, cupid's bow and chin.
pub const contour_channel = 14;
pub const highlight_channel = 15;
/// The upper lash line rides the eye landmarks: each eye's upper lid arc rises
/// into a thin band an eyeliner, mascara, or false-lash tint paints. One band
/// serves all three, which differ by tint color and opacity, not by shape.
pub const lash_line_channel = 16;
/// The retouch regions ride clustered face landmarks: under_eye the band below
/// each eye a soften eases, nasolabial the smile-line fold, sclera the eye-white
/// inside the eye contour minus the iris a lighten brightens, and t_zone the
/// forehead and nose bridge a shine-matte pulls back toward the local mean.
pub const under_eye_channel = 17;
pub const nasolabial_channel = 18;
pub const sclera_channel = 19;
pub const t_zone_channel = 20;
/// A strand-level hair alpha a matte.hair source derives each frame by refining
/// the coarse hair class against the camera luma; hair effects key this channel
/// for a soft feathered edge instead of the hard coarse hair bit.
pub const hair_matte_channel = 21;
/// Scene-parse classes a scene-segmentation model supplies: the sky, the ground
/// plane, and buildings. No scene model is wired in yet, so a lens keying these
/// serves the zero mask and draws nothing until one fills the scene slot.
pub const sky_channel = 22;
pub const ground_channel = 23;
pub const building_channel = 24;

pub fn maskChannelIndex(name: []const u8) ?u8 {
    for (mask_channels, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(i);
    }
    return null;
}

/// A rigid body a model.gltf node rides: the body's pose drives the
/// model matrix once simulation starts.
pub const ClothField = struct {
    /// Grid resolution and world-space size of the cloth sheet.
    cols: u32,
    rows: u32,
    width: f32,
    height: f32,
};

pub const HairField = struct {
    /// Strand count, vertices per strand, and strand length in metres.
    strands: u32,
    verts: u32,
    length: f32,
};

pub const BalloonField = struct {
    /// Rest radius in metres, subdivision level of the sphere shell (0..3),
    /// and internal pressure: positive inflates, zero leaves it limp.
    radius: f32,
    subdivisions: u32,
    pressure: f32,
    /// Pin the top cap so it hangs in place (a balloon); false drops it as a
    /// free soft body that collides with rigid bodies and squishes on impact.
    pinned: bool = true,
};

pub const ParticleField = struct {
    /// Particle count and the fountain's gravity, launch speed, and lifetime.
    count: u32,
    gravity: f32,
    speed: f32,
    lifetime: f32,
    /// When true, each point fades out over its life (alpha-blended) rather
    /// than drawing at full opacity until it respawns.
    fade: bool = false,
    /// The rgb a point cools toward as it dies; set, a point starts at the
    /// node colour and crosses to this by the end of its life (an ember
    /// glowing hot then cooling). Null keeps the node colour throughout.
    cool: ?[3]f32 = null,
    /// Sprite size in pixels (1 to 64) for a fading fountain, drawn as
    /// camera-facing quads; 0 lets the engine pick a visible default.
    size: u32 = 0,
    /// When true, fading sprites blend additively so overlaps brighten - a
    /// glowing fire look rather than a flat alpha composite.
    glow: bool = false,
    /// The stem of a sprite image (assets/<stem>.png) each fading sprite is
    /// textured with, shaping the point beyond the soft round default. Null
    /// draws the built-in soft round sprite.
    sprite: ?[]const u8 = null,
    /// The emission shape: fountain (default), rain, burst, ring, cone, sphere.
    pattern: []const u8 = "fountain",
    /// The rgb each particle is drawn at; null uses the engine's warm default.
    color: ?[3]f32 = null,
    /// 0..1 fractions varying launch speed and lifetime per particle.
    speed_spread: f32 = 0,
    lifetime_spread: f32 = 0,
    /// Velocity damping per second (drag) and a constant wind force.
    drag: f32 = 0,
    wind: [3]f32 = .{ 0, 0, 0 },
    /// A deterministic swirl amplitude added to velocity.
    turbulence: f32 = 0,
    /// Curl-noise amplitude: a divergence-free swirl for organic smoke and
    /// fire churn.
    curl: f32 = 0,
    /// How much speed a particle keeps when it bounces off the floor or a
    /// collider (0 stops dead, 1 a perfect bounce).
    bounce: f32 = 0.5,
    /// A point particles are pulled toward and how strongly (a gravity well).
    attract: ?[3]f32 = null,
    attract_strength: f32 = 0,
    /// Orbital swirl strength around the vertical axis.
    vortex: f32 = 0,
    /// A floor height particles bounce off; null falls through.
    floor: ?f32 = null,
    /// How far a sprite stretches along its screen velocity (streaks); 0 round.
    stretch: f32 = 0,
    /// Frames in a square sprite sheet flip-booked over life; 1 is a still.
    frames: u32 = 1,
    /// Trail length: recent positions drawn behind each particle as a fading
    /// ribbon (a comet tail); 0 or 1 is no trail.
    trail: u32 = 0,
    /// Draw the trail history as one solid connected ribbon strip per particle
    /// instead of separate billboards. Needs `trail` set for the history.
    ribbon: bool = false,
    /// Emit everything once and let it die out, rather than looping.
    oneshot: bool = false,
    /// Sprite size in pixels at death, if the size changes over life.
    size_end: ?u32 = null,
    /// Turns a textured sprite spins over its life.
    spin: f32 = 0,
    /// Sphere colliders particles bounce off, each [x, y, z, radius].
    colliders: []const [4]f32 = &.{},
    /// Box colliders particles bounce off, each [x, y, z, hx, hy, hz].
    box_colliders: []const [6]f32 = &.{},
    /// Infinite plane colliders particles bounce off, each [nx, ny, nz, d].
    plane_colliders: []const [4]f32 = &.{},
    /// Draw each particle as a small 3D mesh instead of a flat billboard or
    /// point, sized by `size`. Off by default.
    mesh: bool = false,
    /// The 3D shape a mesh particle draws: "octahedron" (default), "cube", or
    /// "tetra". Borrowed for the system's lifetime.
    mesh_shape: []const u8 = "octahedron",
    /// Sub-emitter: children each particle bursts into when it dies (a firework
    /// shell opening into sparks), plus their launch speed and lifetime. 0 off.
    sub_count: u32 = 0,
    sub_speed: f32 = 3.0,
    sub_lifetime: f32 = 0.8,
    /// Run the sim on the GPU compute path at crowd scale where the backend
    /// supports it; otherwise the identical CPU sim runs. A gravity fountain.
    gpu: bool = false,
    /// Run a 2D smoothed-particle-hydrodynamics fluid instead of the fountain:
    /// the particles carry density and pressure and pool under gravity.
    sph: bool = false,
    /// Draw a 3D-mesh particle cloud with one instanced call instead of one
    /// draw per particle - the same pixels, at crowd scale.
    instanced: bool = false,
};

/// The prebuilt VFX asset library: a named preset expands to a tuned particle
/// config an author can then override field by field. Returns null for an
/// unknown name.
pub fn particlePreset(name: []const u8) ?ParticleField {
    if (std.mem.eql(u8, name, "fire")) return .{ .count = 220, .pattern = "cone", .gravity = -1.4, .speed = 0.7, .speed_spread = 0.4, .lifetime = 1.3, .lifetime_spread = 0.4, .curl = 3.5, .drag = 0.6, .fade = true, .glow = true, .size = 16, .size_end = 2, .color = .{ 1.0, 0.6, 0.2 }, .cool = .{ 0.5, 0.05, 0.02 } };
    if (std.mem.eql(u8, name, "smoke")) return .{ .count = 180, .pattern = "cone", .gravity = -0.7, .speed = 0.5, .speed_spread = 0.5, .lifetime = 2.6, .lifetime_spread = 0.4, .curl = 2.0, .drag = 1.1, .fade = true, .size = 8, .size_end = 34, .color = .{ 0.55, 0.55, 0.58 }, .cool = .{ 0.2, 0.2, 0.22 } };
    if (std.mem.eql(u8, name, "magic")) return .{ .count = 240, .pattern = "sphere", .gravity = 0.0, .speed = 0.3, .lifetime = 2.2, .lifetime_spread = 0.5, .curl = 2.5, .vortex = 2.4, .attract = .{ 0.0, 0.2, 0.0 }, .attract_strength = 1.3, .fade = true, .glow = true, .spin = 3.0, .size = 10, .size_end = 3, .color = .{ 0.6, 0.3, 1.0 }, .cool = .{ 0.2, 0.8, 1.0 } };
    if (std.mem.eql(u8, name, "sparks")) return .{ .count = 200, .pattern = "burst", .gravity = 6.0, .speed = 3.0, .speed_spread = 0.6, .lifetime = 0.9, .lifetime_spread = 0.5, .drag = 0.8, .fade = true, .glow = true, .stretch = 2.5, .size = 6, .size_end = 1, .color = .{ 1.0, 0.85, 0.35 }, .cool = .{ 0.9, 0.2, 0.05 } };
    return null;
}

pub const GradeField = struct {
    /// A grade.pass node's color adjustment. Defaults are the identity:
    /// exposure in stops, brightness an additive lift, contrast and
    /// saturation multipliers around 1, temperature and tint the white
    /// balance axes, hue in degrees, grayscale/invert 0..1, posterize a level count.
    exposure: f32 = 0,
    contrast: f32 = 1,
    saturation: f32 = 1,
    temperature: f32 = 0,
    brightness: f32 = 0,
    hue: f32 = 0,
    tint: f32 = 0,
    grayscale: f32 = 0,
    invert: f32 = 0,
    posterize: f32 = 0,
    /// An optional mask channel: with one named, the grade applies only inside
    /// that region (a teeth-whiten, an eye-brighten, a skin-tone lift); with none
    /// the whole frame is graded.
    mask_channel: ?u8 = null,
};

pub const DehazeField = struct {
    /// A dehaze.pass node's strength (0..1): how strongly the dark-channel
    /// transmission recovery lifts the atmospheric veil off the frame.
    strength: f32 = 1,
};

pub const RelightField = struct {
    /// A relight.pass node's directional key light: `strength` (0..1) how far it
    /// brightens the light side and shades the far side, `angle` the light
    /// direction in degrees (0 lights from the right).
    strength: f32 = 1,
    angle: f32 = 0,
};

pub const GlareField = struct {
    /// A glare.pass node's specular rolloff: `strength` (0..1) how far a pixel
    /// above `threshold` luma is pulled back down, so blown speculars recover.
    strength: f32 = 1,
    threshold: f32 = 0.8,
};

pub const VignetteField = struct {
    /// A vignette.pass node's radial luma-gain: `strength` scales the gain at the
    /// corner (positive lifts a darkened lens vignette, negative sinks the edges
    /// for a stylistic one), rolled in from `radius` (0..1 of the half-diagonal,
    /// inside which the frame is untouched) out to the corner.
    strength: f32 = 0.5,
    radius: f32 = 0.5,
};

pub const LowLightField = struct {
    /// A lowlight.pass node's night lift: `strength` (0..1) raises the shadows
    /// with a gamma curve while holding the highlights, and `denoise` (0..1)
    /// blends the shadows toward their neighbourhood to damp the noise a lift
    /// exposes. Both 0 leaves the frame untouched.
    strength: f32 = 0.6,
    denoise: f32 = 0.5,
};

pub const UndistortField = struct {
    /// An undistort.pass node's `strength` (0..1) blends toward the lens-corrected
    /// sample. The radial coefficients and principal point come from the camera
    /// intrinsics the host submits; with none submitted the node is inert.
    strength: f32 = 1,
};

pub const BloomField = struct {
    /// A bloom.pass node's glow: threshold is the luma above which a pixel
    /// blooms, intensity how strongly the blurred highlights add back.
    threshold: f32 = 0.7,
    intensity: f32 = 0.6,
};

pub const DofField = struct {
    /// A dof.pass node's focus plane (0..1 in the submitted depth's
    /// near..far range) and blur strength (how sharply the frame softens
    /// with distance from that plane).
    focus: f32 = 0.5,
    strength: f32 = 4.0,
};

pub const FogField = struct {
    /// A fog.pass node's fog color (rgb, 0..1) and density (how quickly the
    /// frame fades toward it with depth). Default a light haze.
    r: f32 = 0.7,
    g: f32 = 0.75,
    b: f32 = 0.8,
    density: f32 = 1.0,
};

pub const OutlineField = struct {
    /// An outline.pass node's line color (rgb, 0..1) and the jump between
    /// neighbors above which an outline draws. Default a black line.
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    threshold: f32 = 0.08,
    /// The mask channel whose edge is outlined; null traces the submitted
    /// depth instead, so an outline can rim a segmentation class or the depth.
    mask_channel: ?u8 = null,
};

pub const OccluderField = struct {
    /// An occluder.pass node reveals the head over the composited frame so 3D
    /// content drawn behind it is hidden by the head. expand grows the
    /// silhouette (frame fractions), softness feathers its edge, and mask names
    /// the landmark matte channel it reveals, the head by default.
    expand: f32 = 0.0,
    softness: f32 = 0.02,
    mask_channel: u8 = head_channel,
};

pub const CutoutField = struct {
    /// A cutout.pass node isolates the face: the matte keys the camera frame
    /// through, and the rest of the frame is replaced by a flat color. color is
    /// that background (rgb, 0..1), softness feathers the matte edge, and mask
    /// names the matte channel it keeps, the head by default.
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    softness: f32 = 0.02,
    mask_channel: u8 = head_channel,
};

/// How a tint.pass folds its color into the masked region. normal blends
/// straight toward the color (the makeup default); multiply darkens through it
/// for a contour shadow; screen lightens through it for a highlight, each
/// keeping the underlying skin texture the flat blend would wash out.
pub const TintBlend = enum { normal, multiply, screen };

/// The surface finish a tint.pass layer takes on within its mask, derived
/// from the frame's own highlights since a 2D camera makeup has no per-pixel
/// normal. matte is the flat blend today's tint already draws; gloss, shimmer,
/// and metallic each add a sheen on top of it.
pub const TintFinish = enum { matte, gloss, shimmer, metallic };

pub const TintField = struct {
    /// A tint.pass node's color (rgb, 0..1) and the opacity it blends into
    /// the masked region, so a face-part matte reads as a soft makeup layer.
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
    opacity: f32 = 0.5,
    /// The mask channel the tint fills; a tint naming none is inert.
    mask_channel: ?u8 = null,
    /// When set by "source": "reference", the color comes from the makeup
    /// reference sampled for this channel, not the static rgb above.
    from_reference: bool = false,
    /// How the color folds into the region: straight blend, darken, or lighten.
    blend: TintBlend = .normal,
    /// The finish the layer wears: matte is the flat default, gloss lifts the
    /// region's real highlights, shimmer adds a stable micro-glint, metallic
    /// drives a stronger sheen with a contrast boost.
    finish: TintFinish = .matte,
};

pub const SmoothField = struct {
    /// A smooth.pass node's retouch amount (-1..1): positive blends the masked
    /// region toward a local average (smooth), negative pushes away from it
    /// (sharpen). mask_channel is the region it acts on.
    amount: f32 = 0.5,
    /// The mask channel the smooth acts on; a smooth naming none is inert.
    mask_channel: ?u8 = null,
};

pub const PaintField = struct {
    /// A paint.face node lays the lens texture (assets/<id>.png) onto the
    /// tracked face through the face mesh UVs. opacity scales how strongly it
    /// sits on the skin.
    opacity: f32 = 1.0,
    /// The face region the material is confined to within the mesh; null
    /// covers the whole face, the full-face image projection case.
    mask_channel: ?u8 = null,
    /// How the texture folds onto the skin: straight over, multiply for an ink
    /// tattoo that darkens the skin, or screen for a lightening projection.
    blend: TintBlend = .normal,
};

pub const SwapField = struct {
    /// A face.swap node warps a donor face (assets/<id>.png, baked in the
    /// canonical face-mesh UVs) onto the live tracked mesh, blending it inside
    /// the face with a feathered seam. opacity scales the swap strength.
    opacity: f32 = 1.0,
    /// The seam softness: how much of the silhouette-to-interior ramp the blend
    /// fades over, so the donor meets the surrounding skin without a hard edge.
    feather: f32 = 0.5,
    /// An optional face region the swap is further confined to within the mesh;
    /// null lets the face mesh and its feather define the region.
    mask_channel: ?u8 = null,
};

pub const LashField = struct {
    /// A mesh.lashes node's lash strip: a tint colour (rgb, 0..1) and the
    /// opacity it blends over the frame. length is how far each strand rises
    /// off the lid, curl how far its tip sweeps, both as fractions of eye
    /// height, so the strip scales with the tracked face.
    r: f32 = 0.02,
    g: f32 = 0.02,
    b: f32 = 0.03,
    opacity: f32 = 1.0,
    length: f32 = 0.6,
    curl: f32 = 0.25,
};

pub const RetouchField = struct {
    /// A retouch.pass node's selective skin filter over a masked region. blemish
    /// is a wider edge-aware smooth that evens small spots while keeping real
    /// edges and skin texture; shine pulls bright pixels back toward the local
    /// mean to matte a specular highlight. amount (0..1) scales the effect.
    mode: enum { blemish, shine } = .blemish,
    amount: f32 = 0.5,
    /// The mask channel the retouch acts on; a retouch naming none is inert.
    mask_channel: ?u8 = null,
};

pub const MatteField = struct {
    /// A matte.refine node's guided edge refinement: frame luminance guides where
    /// the matte alpha snaps to a real image edge versus where it smooths, lifting
    /// a coarse matte toward the crisp hair and fur boundary the frame carries.
    /// radius is reach in texels, sensitivity the edge rejection, strength the mix.
    radius: f32 = 2.0,
    sensitivity: f32 = 8.0,
    strength: f32 = 1.0,
    /// The mask channel this refines (hair by default use); null refines the
    /// submitted depth instead, so the pass has a source with no segmenter.
    mask_channel: ?u8 = null,
};

pub const HairMatteField = struct {
    /// A matte.hair source's guided refinement of the coarse hair class against
    /// the camera luma, so the published hair_matte channel carries a soft
    /// strand alpha, not the hard hair bit. radius is reach in texels,
    /// sensitivity the edge rejection, strength the mix toward the refined.
    radius: f32 = 2.5,
    sensitivity: f32 = 12.0,
    strength: f32 = 1.0,
};

pub const StylizeField = struct {
    /// A stylize.pass node's artistic mode and its parameters: strength drives
    /// the sketch edge and emboss depth, threshold and levels the toon edge
    /// cutoff and colour quantization, and a crosshatch reads strength as its
    /// stroke weight. Defaults match the source filters GPUPixel ships.
    mode: enum { sketch, toon, emboss, crosshatch } = .sketch,
    strength: f32 = 1.0,
    threshold: f32 = 0.2,
    levels: f32 = 10.0,
};

pub const EdgeField = struct {
    /// An edge.pass node's detector. sobel is a single-pass 3x3 gradient
    /// magnitude; canny chains a blur, directional sobel, non-maximum
    /// suppression and weak-pixel hysteresis into thin binary edges.
    mode: enum { sobel, canny } = .sobel,
    /// canny's hysteresis band: an edge fades in from low to high gradient
    /// magnitude. sobel ignores both.
    low_threshold: f32 = 0.1,
    high_threshold: f32 = 0.5,
    /// canny's pre-blur radius in texels; sobel ignores it.
    blur_radius: f32 = 4.0,
    /// sobel's edge-magnitude gain; canny ignores it.
    strength: f32 = 1.0,
    /// Draw dark edges on a light field instead of the default light on dark.
    invert: bool = false,
};

/// The most local push/pull points a liquify warp sums in one pass.
pub const warp_point_max = 8;

/// The flat float layout a warp.pass node packs for the renderer: a ten-float
/// header, then warp_point_max points as (x, y, dx, dy), then their radii.
pub const warp_params_len = 10 + warp_point_max * 5;

pub const LiquifyPoint = struct {
    /// One liquify push point: a position that pulls nearby pixels along its
    /// direction, the pull fading smoothly to nothing by its falloff radius.
    x: f32 = 0.5,
    y: f32 = 0.5,
    /// Push direction scaled by magnitude, in normalized uv.
    dx: f32 = 0,
    dy: f32 = 0,
    /// The falloff radius the push fades to zero at.
    radius: f32 = 0.1,
};

pub const WarpField = struct {
    /// A warp.pass node's geometric distortion, all radial around a center
    /// within a radius: the two sphere modes bend the frame through glass,
    /// bulge, pinch and swirl displace it, liquify sums push points, and
    /// face_scale scales the whole tracked face about its own center.
    mode: enum { glass_sphere, sphere_refraction, bulge, pinch, swirl, liquify, face_scale } = .glass_sphere,
    /// The distortion center in normalized frame coordinates.
    center_x: f32 = 0.5,
    center_y: f32 = 0.5,
    /// The distortion radius (0..1). A pixel beyond it passes through, or for
    /// sphere_refraction goes black.
    radius: f32 = 0.25,
    /// How hard the warp pushes: the displacement scale for bulge, pinch,
    /// swirl and liquify, the refraction blend for the two sphere modes, and
    /// the signed face scale for face_scale (positive enlarges, negative
    /// shrinks). Zero is identity.
    strength: f32 = 1.0,
    /// The glass index of refraction the two sphere modes bend the view ray by.
    refractive_index: f32 = 0.71,
    /// Correct the radius for the frame's own aspect so the region stays a
    /// circle on screen; off treats the frame as square.
    aspect_auto: bool = true,
    /// Mirror the displacement across a vertical axis so the warp reshapes
    /// both sides at once. Off leaves it one-sided. Applies to the bulge,
    /// pinch, swirl and liquify displacement modes, not the sphere refractions.
    symmetry: bool = false,
    /// The vertical mirror axis in normalized x when symmetry is on.
    symmetry_x: f32 = 0.5,
    /// liquify only: local push/pull points summed with smooth falloff, each
    /// pulling nearby pixels along its direction. Slots past point_count stay
    /// zeroed and contribute nothing.
    points: [warp_point_max]LiquifyPoint = [_]LiquifyPoint{.{}} ** warp_point_max,
    point_count: usize = 0,
    /// The mask channel the displacement is confined to: only pixels the mask
    /// marks move, the rest stay put, so a body-slim reshapes the person and
    /// leaves the background behind them untouched. Null warps the whole frame.
    mask_channel: ?u8 = null,
};

pub const ReshapeField = struct {
    /// A reshape.bank node's per-region face sculpt: sixty-six landmark
    /// driven deformations, each in [-1,1] with 0 the identity. Every field
    /// warps the frame around one facial region and decays to identity away
    /// from it, so the banks compose without a global resample.
    nose_width: f32 = 0,
    nose_bridge_width: f32 = 0,
    nose_bridge_height: f32 = 0,
    nose_tip_size: f32 = 0,
    nose_tip_height: f32 = 0,
    nose_length: f32 = 0,
    nostril_size: f32 = 0,
    nose_scale: f32 = 0,
    jaw_width: f32 = 0,
    jaw_slim: f32 = 0,
    jaw_left: f32 = 0,
    jaw_right: f32 = 0,
    jaw_angle: f32 = 0,
    jaw_height: f32 = 0,
    jaw_v_line: f32 = 0,
    chin_length: f32 = 0,
    chin_width: f32 = 0,
    chin_point: f32 = 0,
    chin_height: f32 = 0,
    chin_forward: f32 = 0,
    chin_size: f32 = 0,
    lip_size: f32 = 0,
    lip_width: f32 = 0,
    lip_height: f32 = 0,
    lip_upper: f32 = 0,
    lip_lower: f32 = 0,
    mouth_position: f32 = 0,
    mouth_corner: f32 = 0,
    cupid_bow: f32 = 0,
    philtrum_length: f32 = 0,
    cheek_fullness_l: f32 = 0,
    cheek_fullness_r: f32 = 0,
    cheek_slim_l: f32 = 0,
    cheek_slim_r: f32 = 0,
    cheekbone_height: f32 = 0,
    cheekbone_width: f32 = 0,
    cheek_lower_slim: f32 = 0,
    cheek_scale: f32 = 0,
    brow_height_l: f32 = 0,
    brow_height_r: f32 = 0,
    brow_tilt: f32 = 0,
    brow_thickness: f32 = 0,
    brow_distance: f32 = 0,
    brow_peak: f32 = 0,
    forehead_height: f32 = 0,
    forehead_width: f32 = 0,
    forehead_round: f32 = 0,
    forehead_size: f32 = 0,
    eye_size_l: f32 = 0,
    eye_size_r: f32 = 0,
    eye_width: f32 = 0,
    eye_height: f32 = 0,
    eye_distance: f32 = 0,
    eye_tilt: f32 = 0,
    eye_inner_corner: f32 = 0,
    eye_outer_corner: f32 = 0,
    eye_lower: f32 = 0,
    eye_scale: f32 = 0,
    face_slim: f32 = 0,
    face_width: f32 = 0,
    face_length: f32 = 0,
    face_v_shape: f32 = 0,
    temple_width: f32 = 0,
    face_scale: f32 = 0,
    face_symmetry: f32 = 0,
    face_overall: f32 = 0,
};

pub const TrailField = struct {
    /// A trail.pass node's echo amount (0..1): how much of the previous
    /// frame blends into this one, so moving content leaves a motion trail.
    amount: f32 = 0.6,
};

pub const SsrField = struct {
    /// An ssr.pass node's reflection strength (0..1) and the screen-space
    /// horizon (0..1 down the frame) below which the scene mirrors into a
    /// reflective floor. Default a subtle floor at the lower third.
    strength: f32 = 0.5,
    plane: f32 = 0.66,
};

pub const EnvField = struct {
    /// An env.pass node's sky gradient (top and bottom rgb, 0..1) and overall
    /// intensity, drawn behind the segmented foreground. Default a clear day.
    top_r: f32 = 0.25,
    top_g: f32 = 0.5,
    top_b: f32 = 0.9,
    bottom_r: f32 = 0.85,
    bottom_g: f32 = 0.9,
    bottom_b: f32 = 0.98,
    intensity: f32 = 1.0,
};

/// The direct-manipulation gestures and screen controls a sprite responds to.
/// drag moves it, pinch scales it, rotate turns it, tap_event fires on a tap;
/// slider_param runs it along a track as a slider and carousel_param steps an
/// index on a swipe. All off by default; the spec covers the full behaviour.
pub const Interaction = struct {
    drag: bool = false,
    pinch: bool = false,
    rotate: bool = false,
    tap_event: []const u8 = "",
    slider_param: []const u8 = "",
    slider_vertical: bool = false,
    slider_min: f32 = 0.0,
    slider_max: f32 = 1.0,
    carousel_param: []const u8 = "",
    carousel_count: u32 = 0,

    pub fn any(self: Interaction) bool {
        return self.drag or self.pinch or self.rotate or self.tap_event.len > 0 or
            self.slider_param.len > 0 or self.carousel_param.len > 0;
    }
};

pub const SpriteField = struct {
    /// A sprite.2d node's screen rect in normalized coordinates (origin
    /// top-left, 0..1 across the frame) and its draw opacity. The default
    /// fills the frame at full opacity.
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 1.0,
    h: f32 = 1.0,
    opacity: f32 = 1.0,
    /// The gestures that directly manipulate this sprite, off unless named.
    interaction: Interaction = .{},
    /// A parameter name whose live value overrides `opacity` each frame, so
    /// a param_ramp can fade the sprite or a beat trigger pulse it. Empty
    /// leaves the static opacity in force.
    opacity_param: []const u8 = "",
    /// Parameter names whose live values override the rect each frame, so a
    /// model output (a detected box, a tracked keypoint through an ml.infer
    /// node) can move and size the sprite. Empty leaves the static rect.
    x_param: []const u8 = "",
    y_param: []const u8 = "",
    w_param: []const u8 = "",
    h_param: []const u8 = "",
    /// Frame count for an animated sprite: 1 (default) draws assets/<id>.png
    /// once; N>1 loads assets/<id>_0.png..assets/<id>_(N-1).png and cycles
    /// them at `fps` off the lens clock. Capped so a lens cannot ask for an
    /// unbounded number of textures.
    frames: u32 = 1,
    fps: f32 = 12.0,
    /// A segmentation channel that keys the sprite full-frame against the region
    /// it names. Null draws the sprite over the frame at its rect as usual.
    mask_channel: ?u8 = null,
    /// How a masked sprite composites: `behind` fills where the channel is off
    /// (a greenscreen behind the subject), `over` fills where it is on (a
    /// restyle of that region, e.g. a generative face onto the face matte).
    mask_mode: SpriteMaskMode = .behind,
    /// Over-mode only: how strongly the restyle mixes onto its region, 0 leaves
    /// the frame and 1 is the full restyle; `mask_strength_param` binds it live.
    mask_strength: f32 = 1,
    mask_strength_param: []const u8 = "",
};

pub const SpriteMaskMode = enum { behind, over };

pub const max_sprite_frames = 64;

pub const TextField = struct {
    /// A text.2d node's inline string, the screen rect it fills (same
    /// normalized coordinates as a sprite), its opacity, and the rgb color
    /// its glyphs draw in. The engine rasterizes the string with its
    /// built-in font and draws it like a sprite.
    content: []const u8 = "",
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 1.0,
    h: f32 = 0.2,
    opacity: f32 = 1.0,
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    /// Like SpriteField.opacity_param: a parameter name whose live value
    /// overrides the text's opacity each frame. Empty keeps the static one.
    opacity_param: []const u8 = "",
    /// The rgb the glyphs fade toward at their base for a vertical gradient
    /// (top is the main color); null draws a flat fill.
    gradient: ?[3]u8 = null,
    /// Drop a soft shadow down-right behind the glyphs.
    shadow: bool = false,
    /// An outline the glyphs are stroked with; null is no stroke.
    stroke: ?[3]u8 = null,
    /// Extrude the glyphs into a rotated 3D block mesh of this depth (in the
    /// normalized text space); 0 keeps the flat 2D sprite text.
    depth: f32 = 0,
};

pub const VideoField = struct {
    /// A video.texture node's clip, decoded off the platform's hardware
    /// decoder and drawn like a sprite. `source` names the asset
    /// (assets/<source>.mp4); the screen rect and opacity match a sprite's.
    source: []const u8 = "",
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 1.0,
    h: f32 = 1.0,
    opacity: f32 = 1.0,
    /// Playback rate the clip advances at against the lens clock. Zero
    /// holds the first decoded frame.
    fps: f32 = 30.0,
    /// Rewind to the start at the end of the clip rather than holding the
    /// last frame.
    loop: bool = true,
};

pub const LayoutField = struct {
    /// A layout.composite node's head arrangement and the camera base's blend.
    /// arrangement 0 custom..5 overlay matches the ABI; key 0 none, 1 matte,
    /// 2 chroma; chroma is the key color, similarity its match width.
    arrangement: u8 = 4,
    key: u8 = 0,
    chroma: [3]f32 = .{ 0, 0, 0 },
    similarity: f32 = 0,
    opacity: f32 = 1,
};

pub const PhysicsBody = struct {
    shape: enum { box, sphere, cylinder, capsule, hull, mesh },
    /// Box half extents; a sphere reads its radius from [0]; a cylinder or
    /// capsule (axis vertical) reads radius from [0] and half height from [1].
    /// A hull or mesh ignores this and reads its geometry from `hull_points`.
    size: [3]f32,
    /// Local-space points a `hull` body takes the convex hull of, or a `mesh`
    /// body triangulates; empty for the analytic shapes.
    hull_points: []const [3]f32 = &.{},
    /// Triangle indices (three per face) for a concave `mesh` collider; empty
    /// otherwise.
    mesh_indices: []const u32 = &.{},
    /// A `mesh` body with no explicit points derives its collider from the
    /// node's own glb geometry, once that finishes decoding.
    mesh_from_glb: bool = false,
    position: [3]f32,
    /// Orientation in euler degrees (x, y, z), so an elongated shape can lie
    /// on its side or a static collider can tilt. Zero is upright.
    rotation: [3]f32 = .{ 0, 0, 0 },
    /// Surface material: friction (0 slippery, ~1 grippy) and restitution
    /// (0 dead, 1 bouncy). Defaults match the engine's plain body.
    friction: f32 = 0.2,
    restitution: f32 = 0.0,
    /// Confine the body to the z = 0 plane (x/y motion and z spin only) for a
    /// 2D world laid into the 3D scene.
    planar: bool = false,
    /// The engine drives this (kinematic) body to a tracked target each frame:
    /// `head` follows the tracked head pose, so content collides with the head.
    follow: enum { none, head } = .none,
    dynamic: bool,
    /// The engine drives this body's pose from its anchor each frame;
    /// chained bodies hang off it.
    kinematic: bool = false,
    /// The id of the node this body is chained to, and the chain
    /// length, for content hanging off an anchor.
    chain_to: ?[]const u8 = null,
    chain_length: f32 = 0,
    /// How the body links to its `chain_to` anchor: a distance constraint
    /// bounded by `chain_length`, a point (ball) joint it swings about, a
    /// fixed weld that rides the anchor, a hinge that swings in one plane
    /// about z, or a spring that tethers softly and bobs at `chain_length`.
    joint: enum { distance, point, fixed, hinge, spring } = .distance,
    /// Secondary motion: when > 1, the chain is built from this many spring
    /// links through hidden proxy bodies between the anchor and this node, so
    /// the node lags and sways after the anchor moves - jiggle for hair,
    /// jewelry, and tails. 0 or 1 leaves the plain single-link chain.
    jiggle_segments: u32 = 0,
    /// Spring frequency in Hz and damping 0..1 for each jiggle link.
    jiggle_stiffness: f32 = 3.0,
    jiggle_damping: f32 = 0.3,
};

/// How a model.gltf node is steered by the recognized gestures, a turntable
/// input scheme: orbit spins it with a drag, dolly scales it with a pinch, and
/// roll turns it with a two-finger twist. All off unless named.
pub const ModelControl = struct {
    orbit: bool = false,
    dolly: bool = false,
    roll: bool = false,

    pub fn any(self: ModelControl) bool {
        return self.orbit or self.dolly or self.roll;
    }
};

/// One node of a logic.graph, stored raw for the runtime to compile. op is the
/// operation name; a, b and c are either a wired input (a_ref names an earlier
/// node) or an inline literal (a_lit). signal_source and param_name feed the
/// leaf ops; constant is the const op's value.
pub const LogicNodeSpec = struct {
    id: []const u8,
    op: []const u8,
    a_ref: []const u8 = "",
    a_lit: f32 = 0,
    b_ref: []const u8 = "",
    b_lit: f32 = 0,
    c_ref: []const u8 = "",
    c_lit: f32 = 0,
    constant: f32 = 0,
    signal_source: []const u8 = "",
    param_name: []const u8 = "",
};

/// A logic.graph node's raw graph: its nodes, which node is the output, and the
/// parameter the output value drives each tick.
pub const LogicGraphSpec = struct {
    nodes: []const LogicNodeSpec,
    output_id: []const u8,
    output_param: []const u8,
};

/// How an output binding reduces its tensor to the scalar it writes: element
/// takes the value at index, argmax takes the index of the tensor's largest
/// element (a classifier's predicted class).
pub const MlReduce = enum { element, argmax };

/// One output binding of an ml.infer node: a scalar drawn from the model's
/// output tensor drives the named parameter each inference, either the element
/// at index or, for a classifier, the argmax over the tensor.
pub const MlOutput = struct {
    tensor: u32 = 0,
    index: u32 = 0,
    reduce: MlReduce = .element,
    param: []const u8,
};

/// Binds a whole output tensor of an ml.infer node as a segmentation mask: the
/// tensor is a single-channel image the engine resamples to the mask resolution
/// and feeds to the named mask channel, so a lens author's own segmenter drives
/// the same compositing the built-in segmenters do.
pub const MlMask = struct {
    tensor: u32 = 0,
    channel: u8 = 0,
};

/// Binds a whole output tensor of an ml.infer node as a stylized RGB image:
/// the tensor is a three-channel image the engine uploads to the named
/// sprite.2d node's texture each frame, so a model that restyles the frame
/// (a neural style-transfer net) draws through that sprite over the camera.
pub const MlStyle = struct {
    tensor: u32 = 0,
    sprite: []const u8,
};

/// An ml.infer node's model slot: the bundle-relative model file, the input
/// size the camera frame is resized to (zero keeps the model's own), the
/// output-to-parameter bindings a lens reads, and optional output-to-mask and
/// output-to-sprite bindings for an author segmenter or a restyle net.
pub const MlField = struct {
    model: []const u8,
    input_width: u32 = 0,
    input_height: u32 = 0,
    outputs: []const MlOutput,
    mask: ?MlMask = null,
    style: ?MlStyle = null,
    /// A bundled reference image (assets/<stem>.png) sampled into the model's
    /// second input, for a net conditioned on a reference (makeup, style, or
    /// identity transfer). Empty for a one-input model.
    aux_reference: []const u8 = "",
    /// A two-input net whose second input is the previous output frame, for a
    /// recurrent pass that fuses across time (denoise, stabilize, upscale).
    /// Mutually exclusive with aux_reference.
    temporal: bool = false,
};

/// A diffusion node's restyle slot: the three bundled models the loop runs (a
/// VAE encoder, a UNet, a VAE decoder), an optional precomputed text embedding
/// the UNet conditions on, the sprite the restyled frame draws through, and the
/// sampler settings (few-step count, img2img strength, and noise seed).
pub const DiffusionField = struct {
    encoder: []const u8,
    unet: []const u8,
    decoder: []const u8,
    text_embedding: []const u8 = "",
    sprite: []const u8,
    steps: u32 = 4,
    strength: f32 = 0.6,
    seed: u64 = 0,
    /// Temporal coherence: 0 restyles each frame independently, higher values
    /// hold the flow-warped previous frame against flicker (img2img only).
    coherence: f32 = 0,
};

pub const SplatDraw = enum { points, mesh };

/// Where a splat.cloud's model reads its input. `camera` lifts the live frame
/// each tick; `selfie` runs once on a still submitted through the ABI, so a
/// photoreal avatar is generated from one photo and then held.
pub const SplatSource = enum { camera, selfie };

pub const SplatField = struct {
    /// A splat.cloud node lifts a frame into 3D with a bundled model whose output
    /// is a flat xyz list. `source` picks the input (live camera or a submitted
    /// selfie); `draw` the form (`points` billboards or a `mesh` grid surface);
    /// `point` the size, r,g,b the color, `colored` a per-point color from rgb.
    model: []const u8,
    source: SplatSource = .camera,
    draw: SplatDraw = .points,
    point: f32 = 6.0,
    r: f32 = 0.9,
    g: f32 = 0.85,
    b: f32 = 0.8,
    colored: bool = false,
};

pub const Node = struct {
    id: []const u8,
    type: []const u8,
    inputs: []const NodeInput,
    params: []const NodeParam,
    /// Index into mask_channels, set only when the manifest names one.
    mask_channel: ?u8 = null,
    /// True when a model.gltf node anchors to the tracked face.
    face_anchor: bool = false,
    /// True when a face-anchored model.gltf retargets the tracked expression:
    /// each morph target named for an ARKit blendshape is driven by that live
    /// blendshape, turning the mesh into an avatar of the user's face.
    retarget: bool = false,
    /// True when a model.gltf drives its jaw-open morph from the submitted audio
    /// envelope, so the mesh mouths speech even with no tracked face.
    talk: bool = false,
    /// True when a model.gltf node anchors to every tracked body.
    body_anchor: bool = false,
    /// True when a model.gltf node draws once per bone of every tracked body.
    skeleton_anchor: bool = false,
    /// True when a model.gltf node anchors to the tracked world.
    world_anchor: bool = false,
    /// Set when a model.gltf node is turntable-controlled by the gestures.
    control: ?ModelControl = null,
    /// Set on a logic.graph node: its raw graph the runtime compiles.
    logic_graph: ?LogicGraphSpec = null,
    /// Set on an ml.infer node: the bring-your-own model slot.
    ml: ?MlField = null,
    diffusion: ?DiffusionField = null,
    /// Set on a splat.cloud node: the model that lifts the frame to a point cloud.
    splat: ?SplatField = null,
    /// Set when the manifest gives the node a rigid body.
    physics: ?PhysicsBody = null,
    /// Set when the node is a simulated cloth sheet instead of a glb.
    cloth: ?ClothField = null,
    /// Set when the node is a pressurised soft-body balloon instead of a glb.
    balloon: ?BalloonField = null,
    /// Set when the node is simulated strand hair instead of a glb.
    hair: ?HairField = null,
    /// Set when the node is a particle fountain instead of a glb.
    particles: ?ParticleField = null,
    /// model.gltf only: a parameter name per animation clip, in clip
    /// order, whose live value is that clip's blend weight. Empty means
    /// the node plays its first clip at full weight. A clip past this
    /// list weighs nothing.
    clip_weights: []const []const u8 = &.{},
    /// model.gltf only: a parameter name per morph target, in target
    /// order, whose live value is that target's blend weight. Empty leaves
    /// the mesh unmorphed. A target past this list contributes nothing.
    morph_weights: []const []const u8 = &.{},
    /// Set only on a grade.pass node: its parametric color grade.
    grade: ?GradeField = null,
    /// Set only on a dehaze.pass node: its dark-channel dehaze strength.
    dehaze: ?DehazeField = null,
    /// Set only on a relight.pass node: its directional key light.
    relight: ?RelightField = null,
    /// Set only on a glare.pass node: its specular-highlight rolloff.
    glare: ?GlareField = null,
    /// Set only on a vignette.pass node: its radial luma-gain.
    vignette: ?VignetteField = null,
    /// Set only on a lowlight.pass node: its shadow lift and denoise.
    lowlight: ?LowLightField = null,
    /// Set only on an undistort.pass node: its correction strength.
    undistort: ?UndistortField = null,
    /// Set only on a shader.pass node that authors a material node graph
    /// instead of naming a built-in shader; lowers to a fragment shader.
    material: ?material.Graph = null,
    /// Set only on a bloom.pass node: its glow threshold and intensity.
    bloom: ?BloomField = null,
    /// Set only on a dof.pass node: its focus plane and blur strength.
    dof: ?DofField = null,
    /// Set only on a fog.pass node: its fog color and density.
    fog: ?FogField = null,
    /// Set only on an outline.pass node: its line color and depth threshold.
    outline: ?OutlineField = null,
    /// Set only on an occluder.pass node: its silhouette expand, edge softness,
    /// and the head-matte channel it reveals.
    occluder: ?OccluderField = null,
    /// Set only on a cutout.pass node: its background color, edge softness, and
    /// the face-matte channel it keeps.
    cutout: ?CutoutField = null,
    /// Set only on a tint.pass node: its color, opacity, and mask channel.
    tint: ?TintField = null,
    /// Set only on a smooth.pass node: its amount and mask channel.
    smooth: ?SmoothField = null,
    /// Set only on a paint.face node: the opacity, face region, and blend it
    /// lays its texture onto the face with.
    paint: ?PaintField = null,
    /// Set only on a face.swap node: the opacity, seam feather, and optional
    /// region the donor face is warped onto the tracked face with.
    swap: ?SwapField = null,
    /// Set only on a mesh.lashes node: the colour, opacity, length, and curl
    /// of the lash strip it rises off the upper lid.
    lashes: ?LashField = null,
    /// Set only on a retouch.pass node: its selective-filter mode, amount, and
    /// mask channel.
    retouch: ?RetouchField = null,
    /// Set only on a matte.refine node: its guided edge-refinement parameters
    /// and the mask channel (or depth) it refines.
    matte: ?MatteField = null,
    /// Set only on a matte.hair node: the guided-refinement parameters it lifts
    /// the coarse hair class into the strand-level hair_matte channel with.
    hair_matte: ?HairMatteField = null,
    /// Set only on a stylize.pass node: its artistic mode and parameters.
    stylize: ?StylizeField = null,
    /// Set only on an edge.pass node: its detector mode and parameters.
    edge: ?EdgeField = null,
    /// Set only on a warp.pass node: its distortion mode and parameters.
    warp: ?WarpField = null,
    /// Set only on a reshape.bank node: its sixty-six per-region face sculpt
    /// amounts.
    reshape: ?ReshapeField = null,
    /// Set only on a trail.pass node: its motion-trail echo amount.
    trail: ?TrailField = null,
    /// Set only on an ssr.pass node: its reflection strength and floor plane.
    ssr: ?SsrField = null,
    /// Set only on an env.pass node: its sky gradient colors and intensity.
    env: ?EnvField = null,
    /// Set only on a layout.composite node: the head arrangement it drives.
    layout: ?LayoutField = null,
    /// Set only on a sprite.2d node: the screen rect and opacity it draws
    /// its image at.
    sprite: ?SpriteField = null,
    /// Set only on a text.2d node: the string, rect, opacity, and color it
    /// draws.
    text: ?TextField = null,
    /// Set only on a video.texture node: the clip source, rect, opacity, and
    /// playback rate it decodes and draws at.
    video: ?VideoField = null,
    /// The inline script source, set only for a "script" node. It runs each
    /// tick to drive parameters and never joins the composite chain.
    script: ?[]const u8 = null,
};

pub const ActionKind = enum {
    param_ramp,
    param_set,
    show,
    hide,
    play_animation,
    swap_subgraph,
    reset_timer,
    /// Plays a sound: target is the bundle-relative sound path.
    play_sound,
    /// Counter changes: target names the counter, to is the set value.
    increment_counter,
    reset_counter,
    set_counter,
    /// Device haptic: target names the style, to is the 0..1 intensity.
    haptic,
};

pub const Curve = enum { linear, ease_in_quad, ease_out_quad, ease_in_out_quad, ease_in_out_cubic, ease_in_out_sine, spring };

pub const Action = struct {
    kind: ActionKind,
    target: []const u8 = "",
    to: f32 = 0,
    duration_ms: u32 = 0,
    curve: Curve = .linear,
    stiffness: f32 = 0,
    damping: f32 = 0,
};

pub const Trigger = struct {
    when_source: []const u8,
    action: Action,
};

/// A range over the ABI's major.minor: an optional lower bound (>= or >)
/// and optional upper bound (< or <=), space separated, each
/// `major.minor`. Anything wider is out of scope for GLF 1.0, which
/// only ever needs to express "at least this, before that".
pub const EngineRange = struct {
    has_min: bool = false,
    min_major: u16 = 0,
    min_minor: u16 = 0,
    min_inclusive: bool = true,
    has_max: bool = false,
    max_major: u16 = 0,
    max_minor: u16 = 0,
    max_inclusive: bool = false,

    pub fn contains(self: EngineRange, major: u16, minor: u16) bool {
        if (self.has_min) {
            const below = major < self.min_major or (major == self.min_major and minor < self.min_minor);
            const at_floor = major == self.min_major and minor == self.min_minor;
            if (below or (!self.min_inclusive and at_floor)) return false;
        }
        if (self.has_max) {
            const above = major > self.max_major or (major == self.max_major and minor > self.max_minor);
            const at_ceiling = major == self.max_major and minor == self.max_minor;
            if (above or (!self.max_inclusive and at_ceiling)) return false;
        }
        return true;
    }
};

/// A lens-level trigger region the tracked device is tested against each tick,
/// feeding the device.in_volume trigger signal. A sphere when `radius` > 0,
/// otherwise an axis-aligned box of `half`-extents, both centered at `center`.
pub const Volume = struct {
    center: [3]f32 = .{ 0, 0, 0 },
    radius: f32 = 0,
    half: [3]f32 = .{ 0, 0, 0 },
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    glf_minor: u16,
    id: []const u8,
    version: []const u8,
    display_name: []const u8,
    engine_compat: EngineRange,
    capabilities: []const Capability,
    parameters: []const Parameter,
    nodes: []const Node,
    triggers: []const Trigger,
    volume: ?Volume = null,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Diagnostic = struct {
    path: []const u8,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn add(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        const path_copy = try self.arena.dupe(u8, path);
        try self.list.append(self.arena, .{ .path = path_copy, .message = message });
    }
};

/// Builds "/a/b/2" style pointers without allocating: a fixed buffer big
/// enough for any path this format's own field/count limits can produce.
const PathStack = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *PathStack, segment: []const u8) usize {
        const mark = self.len;
        if (self.len + 1 + segment.len <= self.buf.len) {
            self.buf[self.len] = '/';
            @memcpy(self.buf[self.len + 1 ..][0..segment.len], segment);
            self.len += 1 + segment.len;
        }
        return mark;
    }

    fn pushIndex(self: *PathStack, index: usize) usize {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{index}) catch unreachable;
        return self.push(s);
    }

    fn pop(self: *PathStack, mark: usize) void {
        self.len = mark;
    }

    fn slice(self: *const PathStack) []const u8 {
        return self.buf[0..self.len];
    }
};

fn jsonDepth(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| blk: {
            var max: usize = 0;
            for (a.items) |item| max = @max(max, jsonDepth(item));
            break :blk max + 1;
        },
        .object => |o| blk: {
            var max: usize = 0;
            var it = o.iterator();
            while (it.next()) |entry| max = @max(max, jsonDepth(entry.value_ptr.*));
            break :blk max + 1;
        },
        else => 0,
    };
}

fn readVec3(value: std.json.Value, out: *[3]f32) bool {
    if (value != .array or value.array.items.len != 3) return false;
    for (value.array.items, 0..) |item, i| out[i] = @floatCast(numberOf(item) orelse return false);
    return true;
}

fn readVec4(value: std.json.Value, out: *[4]f32) bool {
    if (value != .array or value.array.items.len != 4) return false;
    for (value.array.items, 0..) |item, i| out[i] = @floatCast(numberOf(item) orelse return false);
    return true;
}

fn readVec6(value: std.json.Value, out: *[6]f32) bool {
    if (value != .array or value.array.items.len != 6) return false;
    for (value.array.items, 0..) |item, i| out[i] = @floatCast(numberOf(item) orelse return false);
    return true;
}

fn getField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return object.get(name);
}

fn expectObject(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?std.json.ObjectMap {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected an object", .{});
        return null;
    };
    return switch (v) {
        .object => |o| o,
        else => blk: {
            try diags.add(path.slice(), "expected an object", .{});
            break :blk null;
        },
    };
}

fn expectString(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?[]const u8 {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected a string", .{});
        return null;
    };
    return switch (v) {
        .string => |s| s,
        else => blk: {
            try diags.add(path.slice(), "expected a string", .{});
            break :blk null;
        },
    };
}

fn expectArray(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?std.json.Array {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected an array", .{});
        return null;
    };
    return switch (v) {
        .array => |a| a,
        else => blk: {
            try diags.add(path.slice(), "expected an array", .{});
            break :blk null;
        },
    };
}

/// A layout.composite arrangement name to its ABI integer (0 custom by default).
fn arrangementValue(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "side_by_side")) return 1;
    if (std.mem.eql(u8, s, "top_bottom")) return 2;
    if (std.mem.eql(u8, s, "pip")) return 3;
    if (std.mem.eql(u8, s, "grid")) return 4;
    if (std.mem.eql(u8, s, "overlay")) return 5;
    return 0;
}

/// A composite key-mode name to its integer (0 none by default).
fn keyModeValue(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "matte")) return 1;
    if (std.mem.eql(u8, s, "chroma")) return 2;
    return 0;
}

/// The finite f64 range that still narrows to a finite f32. Every numeric
/// field a lens carries is an f32 descriptor; a JSON 1e300 would otherwise
/// cast to inf and feed a body or particle born non-finite.
const f32_limit: f64 = std.math.floatMax(f32);

/// Reads a JSON number, rejecting anything that would not survive the f32
/// narrowing every consumer performs: NaN, inf, or a magnitude past f32's
/// range. Out-of-range reads fall back to the caller's default or diagnostic.
fn numberOf(value: std.json.Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    // Written as a positive test so NaN (all comparisons false) is rejected.
    if (!(n >= -f32_limit and n <= f32_limit)) return null;
    return n;
}

/// Parses "major.minor" strictly: two decimal runs separated by one dot,
/// nothing else.
fn parseMajorMinor(s: []const u8) ?struct { major: u16, minor: u16 } {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    if (std.mem.indexOfScalarPos(u8, s, dot + 1, '.') != null) return null;
    const major = std.fmt.parseInt(u16, s[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u16, s[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn parseEngineCompat(diags: *Diagnostics, path: *PathStack, s: []const u8) error{OutOfMemory}!?EngineRange {
    var range = EngineRange{};
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    var clauses: usize = 0;
    while (it.next()) |clause| {
        clauses += 1;
        if (clauses > 2) {
            try diags.add(path.slice(), "engine_compat takes at most a lower and an upper bound", .{});
            return null;
        }
        var inclusive = true;
        var rest = clause;
        var is_min: bool = undefined;
        if (std.mem.startsWith(u8, rest, ">=")) {
            is_min = true;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, ">")) {
            is_min = true;
            inclusive = false;
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "<=")) {
            is_min = false;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "<")) {
            is_min = false;
            inclusive = false;
            rest = rest[1..];
        } else {
            try diags.add(path.slice(), "engine_compat clause '{s}' must start with >=, >, <=, or <", .{clause});
            return null;
        }
        const parsed = parseMajorMinor(rest) orelse {
            try diags.add(path.slice(), "engine_compat clause '{s}' must name major.minor", .{clause});
            return null;
        };
        if (is_min) {
            if (range.has_min) {
                try diags.add(path.slice(), "engine_compat names two lower bounds", .{});
                return null;
            }
            range.has_min = true;
            range.min_major = parsed.major;
            range.min_minor = parsed.minor;
            range.min_inclusive = inclusive;
        } else {
            if (range.has_max) {
                try diags.add(path.slice(), "engine_compat names two upper bounds", .{});
                return null;
            }
            range.has_max = true;
            range.max_major = parsed.major;
            range.max_minor = parsed.minor;
            range.max_inclusive = inclusive;
        }
    }
    if (clauses == 0) {
        try diags.add(path.slice(), "engine_compat is empty", .{});
        return null;
    }
    return range;
}

fn parseCapabilities(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Capability {
    var out: std.ArrayList(Capability) = .empty;
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const name = switch (item) {
            .string => |s| s,
            else => {
                try diags.add(path.slice(), "expected a capability name", .{});
                continue;
            },
        };
        const cap = std.meta.stringToEnum(Capability, name) orelse {
            try diags.add(path.slice(), "unknown capability '{s}'", .{name});
            continue;
        };
        try out.append(arena, cap);
    }
    return try out.toOwnedSlice(arena);
}

fn parseParamValue(diags: *Diagnostics, path: *PathStack, param_type: ParamType, value: std.json.Value) error{OutOfMemory}!?ParamValue {
    switch (param_type) {
        .float => {
            const n = numberOf(value) orelse {
                try diags.add(path.slice(), "expected a number", .{});
                return null;
            };
            return .{ .float = @floatCast(n) };
        },
        .int => {
            const n = numberOf(value) orelse {
                try diags.add(path.slice(), "expected a number", .{});
                return null;
            };
            // Guard the i32 narrowing: a 1e10 default would trap the cast in a
            // safe build and go UB in release. Positive test rejects NaN too.
            const i32_min: f64 = std.math.minInt(i32);
            const i32_max: f64 = std.math.maxInt(i32);
            if (!(n >= i32_min and n <= i32_max)) {
                try diags.add(path.slice(), "int is out of range", .{});
                return null;
            }
            return .{ .int = @intFromFloat(n) };
        },
        .bool => {
            return switch (value) {
                .bool => |b| .{ .bool = b },
                else => blk: {
                    try diags.add(path.slice(), "expected a bool", .{});
                    break :blk null;
                },
            };
        },
        .color => {
            const array = switch (value) {
                .array => |a| a,
                else => {
                    try diags.add(path.slice(), "expected a 4 element color array", .{});
                    return null;
                },
            };
            if (array.items.len != 4) {
                try diags.add(path.slice(), "color needs exactly 4 components", .{});
                return null;
            }
            var out: [4]f32 = undefined;
            for (array.items, 0..) |c, i| {
                out[i] = @floatCast(numberOf(c) orelse {
                    try diags.add(path.slice(), "color component {d} is not a number", .{i});
                    return null;
                });
            }
            return .{ .color = out };
        },
    }
}

fn parseParameters(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Parameter {
    if (array.items.len > max_parameters) {
        try diags.add(path.slice(), "at most {d} parameters, found {d}", .{ max_parameters, array.items.len });
        return null;
    }
    var out: std.ArrayList(Parameter) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const name_mark = path.push("name");
        const name = try expectString(diags, path, getField(object, "name")) orelse {
            path.pop(name_mark);
            continue;
        };
        path.pop(name_mark);
        if (seen.contains(name)) {
            try diags.add(path.slice(), "duplicate parameter name '{s}'", .{name});
            continue;
        }
        try seen.put(name, {});

        const type_mark = path.push("type");
        const type_str = try expectString(diags, path, getField(object, "type")) orelse {
            path.pop(type_mark);
            continue;
        };
        const param_type = std.meta.stringToEnum(ParamType, type_str) orelse {
            try diags.add(path.slice(), "unknown parameter type '{s}'", .{type_str});
            path.pop(type_mark);
            continue;
        };
        path.pop(type_mark);

        const default_mark = path.push("default");
        const default_value = getField(object, "default") orelse {
            try diags.add(path.slice(), "missing", .{});
            path.pop(default_mark);
            continue;
        };
        const default = try parseParamValue(diags, path, param_type, default_value) orelse {
            path.pop(default_mark);
            continue;
        };
        path.pop(default_mark);

        var min: f32 = 0;
        var max: f32 = 0;
        if (param_type == .float or param_type == .int) {
            const min_mark = path.push("min");
            min = @floatCast(numberOf(getField(object, "min") orelse .null) orelse {
                try diags.add(path.slice(), "missing, required for float and int parameters", .{});
                path.pop(min_mark);
                continue;
            });
            path.pop(min_mark);
            const max_mark = path.push("max");
            max = @floatCast(numberOf(getField(object, "max") orelse .null) orelse {
                try diags.add(path.slice(), "missing, required for float and int parameters", .{});
                path.pop(max_mark);
                continue;
            });
            path.pop(max_mark);
            if (min > max) {
                try diags.add(path.slice(), "min {d} exceeds max {d}", .{ min, max });
                continue;
            }
        }

        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .type = param_type,
            .default = default,
            .min = min,
            .max = max,
        });
    }
    return try out.toOwnedSlice(arena);
}

fn parseBinding(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!?ParamBinding {
    switch (value) {
        .string => |s| {
            if (s.len > 0 and s[0] == '$') {
                return .{ .param_ref = try arena.dupe(u8, s[1..]) };
            }
            try diags.add(path.slice(), "string param bindings must start with $", .{});
            return null;
        },
        .bool => |b| return .{ .literal_bool = b },
        .integer, .float => {
            const n = numberOf(value) orelse {
                try diags.add(path.slice(), "number is out of range", .{});
                return null;
            };
            return .{ .literal_float = @floatCast(n) };
        },
        else => {
            try diags.add(path.slice(), "expected a number, bool, or $parameter reference", .{});
            return null;
        },
    }
}

/// Parses a model.gltf node's array of parameter names (clip_weights or
/// morph_weights): one weight-driving parameter name per clip or target.
/// Rejected on any other node type. Cross-referencing each name against
/// the declared parameters happens in the validation pass.
fn parseWeightNames(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, object: std.json.ObjectMap, node_type: []const u8, field: []const u8) error{OutOfMemory}![]const []const u8 {
    var names: []const []const u8 = &.{};
    if (getField(object, field)) |value| {
        const mark = path.push(field);
        if (!std.mem.eql(u8, node_type, "model.gltf")) {
            try diags.add(path.slice(), "{s} is a model.gltf field, found it on '{s}'", .{ field, node_type });
        } else if (try expectArray(diags, path, value)) |array| {
            var list: std.ArrayList([]const u8) = .empty;
            for (array.items, 0..) |name_value, i| {
                const name_mark = path.pushIndex(i);
                if (try expectString(diags, path, name_value)) |name| {
                    try list.append(arena, try arena.dupe(u8, name));
                }
                path.pop(name_mark);
            }
            names = try list.toOwnedSlice(arena);
        }
        path.pop(mark);
    }
    return names;
}

fn parseNodes(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Node {
    if (array.items.len > max_nodes) {
        try diags.add(path.slice(), "at most {d} nodes, found {d}", .{ max_nodes, array.items.len });
        return null;
    }
    var out: std.ArrayList(Node) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const id_mark = path.push("id");
        const id = try expectString(diags, path, getField(object, "id")) orelse {
            path.pop(id_mark);
            continue;
        };
        path.pop(id_mark);
        if (seen.contains(id)) {
            try diags.add(path.slice(), "duplicate node id '{s}'", .{id});
            continue;
        }
        try seen.put(id, {});

        const type_mark = path.push("type");
        const node_type = try expectString(diags, path, getField(object, "type")) orelse {
            path.pop(type_mark);
            continue;
        };
        path.pop(type_mark);

        var inputs: std.ArrayList(NodeInput) = .empty;
        if (getField(object, "inputs")) |inputs_value| {
            const inputs_mark = path.push("inputs");
            const inputs_object = switch (inputs_value) {
                .object => |o| o,
                else => blk: {
                    try diags.add(path.slice(), "expected an object mapping input names to node ids", .{});
                    break :blk null;
                },
            };
            if (inputs_object) |o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    const source = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => {
                            const field_mark = path.push(entry.key_ptr.*);
                            try diags.add(path.slice(), "expected a node id string", .{});
                            path.pop(field_mark);
                            continue;
                        },
                    };
                    try inputs.append(arena, .{
                        .name = try arena.dupe(u8, entry.key_ptr.*),
                        .source = try arena.dupe(u8, source),
                    });
                }
            }
            path.pop(inputs_mark);
        }

        var params: std.ArrayList(NodeParam) = .empty;
        if (getField(object, "params")) |params_value| {
            const params_mark = path.push("params");
            const params_object = switch (params_value) {
                .object => |o| o,
                else => blk: {
                    try diags.add(path.slice(), "expected an object mapping param names to bindings", .{});
                    break :blk null;
                },
            };
            if (params_object) |o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    const field_mark = path.push(entry.key_ptr.*);
                    const binding = try parseBinding(diags, path, arena, entry.value_ptr.*);
                    path.pop(field_mark);
                    if (binding) |b| {
                        try params.append(arena, .{ .name = try arena.dupe(u8, entry.key_ptr.*), .binding = b });
                    }
                }
            }
            path.pop(params_mark);
        }

        var face_anchor = false;
        var body_anchor = false;
        var skeleton_anchor = false;
        var world_anchor = false;
        var model_control: ?ModelControl = null;
        var logic_graph_spec: ?LogicGraphSpec = null;
        var ml_field: ?MlField = null;
        var physics_body: ?PhysicsBody = null;
        var hair_field: ?HairField = null;
        var particle_field: ?ParticleField = null;
        if (getField(object, "particles")) |pv| {
            const pmark = path.push("particles");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "particles is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (pv != .object) {
                try diags.add(path.slice(), "particles must be an object", .{});
            } else {
                var field: ParticleField = .{ .count = 128, .gravity = 9.8, .speed = 2.0, .lifetime = 2.0 };
                if (getField(pv.object, "preset")) |v| {
                    if (try expectString(diags, path, v)) |preset_name| {
                        if (particlePreset(preset_name)) |preset| {
                            field = preset;
                        } else {
                            try diags.add(path.slice(), "unknown particle preset '{s}'", .{preset_name});
                        }
                    }
                }
                if (getField(pv.object, "count")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 4096) field.count = @intCast(v.integer);
                }
                if (getField(pv.object, "gravity")) |v| field.gravity = @floatCast(numberOf(v) orelse field.gravity);
                if (getField(pv.object, "speed")) |v| field.speed = @floatCast(numberOf(v) orelse field.speed);
                if (getField(pv.object, "lifetime")) |v| field.lifetime = @floatCast(numberOf(v) orelse field.lifetime);
                if (getField(pv.object, "fade")) |v| {
                    if (v == .bool) field.fade = v.bool;
                }
                if (getField(pv.object, "color")) |v| {
                    var rgb: [3]f32 = .{ 0, 0, 0 };
                    if (readVec3(v, &rgb)) field.color = rgb else try diags.add(path.slice(), "particles color must be three numbers", .{});
                }
                if (getField(pv.object, "cool")) |v| {
                    var rgb: [3]f32 = .{ 0, 0, 0 };
                    if (readVec3(v, &rgb)) field.cool = rgb else try diags.add(path.slice(), "particles cool must be three numbers", .{});
                }
                if (getField(pv.object, "size")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 64) field.size = @intCast(v.integer) else try diags.add(path.slice(), "particles size must be an integer 1..64", .{});
                }
                if (getField(pv.object, "glow")) |v| {
                    if (v == .bool) field.glow = v.bool;
                }
                if (getField(pv.object, "sprite")) |v| {
                    if (try expectString(diags, path, v)) |stem| field.sprite = try arena.dupe(u8, stem);
                }
                if (getField(pv.object, "pattern")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        const known = [_][]const u8{ "fountain", "rain", "burst", "ring", "cone", "sphere", "box", "disc", "hemisphere", "face" };
                        var ok = false;
                        for (known) |k| {
                            if (std.mem.eql(u8, name, k)) ok = true;
                        }
                        if (ok) field.pattern = try arena.dupe(u8, name) else try diags.add(path.slice(), "unknown particles pattern '{s}'", .{name});
                    }
                }
                if (getField(pv.object, "speed_spread")) |v| field.speed_spread = @floatCast(numberOf(v) orelse field.speed_spread);
                if (getField(pv.object, "lifetime_spread")) |v| field.lifetime_spread = @floatCast(numberOf(v) orelse field.lifetime_spread);
                if (getField(pv.object, "drag")) |v| field.drag = @floatCast(numberOf(v) orelse field.drag);
                if (getField(pv.object, "turbulence")) |v| field.turbulence = @floatCast(numberOf(v) orelse field.turbulence);
                if (getField(pv.object, "curl")) |v| field.curl = @floatCast(numberOf(v) orelse field.curl);
                if (getField(pv.object, "bounce")) |v| field.bounce = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.bounce)), 0.0, 1.0);
                if (getField(pv.object, "spin")) |v| field.spin = @floatCast(numberOf(v) orelse field.spin);
                if (getField(pv.object, "vortex")) |v| field.vortex = @floatCast(numberOf(v) orelse field.vortex);
                if (getField(pv.object, "attract_strength")) |v| field.attract_strength = @floatCast(numberOf(v) orelse field.attract_strength);
                if (getField(pv.object, "stretch")) |v| field.stretch = @floatCast(numberOf(v) orelse field.stretch);
                if (getField(pv.object, "floor")) |v| field.floor = @floatCast(numberOf(v) orelse 0.0);
                if (getField(pv.object, "attract")) |v| {
                    var target: [3]f32 = .{ 0, 0, 0 };
                    if (readVec3(v, &target)) field.attract = target else try diags.add(path.slice(), "particles attract must be three numbers", .{});
                }
                if (getField(pv.object, "frames")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 64) field.frames = @intCast(v.integer) else try diags.add(path.slice(), "particles frames must be an integer 1..64", .{});
                }
                if (getField(pv.object, "trail")) |v| {
                    if (v == .integer and v.integer >= 0 and v.integer <= 32) field.trail = @intCast(v.integer) else try diags.add(path.slice(), "particles trail must be an integer 0..32", .{});
                }
                if (getField(pv.object, "ribbon")) |v| {
                    if (v == .bool) field.ribbon = v.bool;
                }
                if (getField(pv.object, "wind")) |v| {
                    var w: [3]f32 = .{ 0, 0, 0 };
                    if (readVec3(v, &w)) field.wind = w else try diags.add(path.slice(), "particles wind must be three numbers", .{});
                }
                if (getField(pv.object, "oneshot")) |v| {
                    if (v == .bool) field.oneshot = v.bool;
                }
                if (getField(pv.object, "size_end")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 64) field.size_end = @intCast(v.integer) else try diags.add(path.slice(), "particles size_end must be an integer 1..64", .{});
                }
                if (getField(pv.object, "colliders")) |v| {
                    if (v == .array and v.array.items.len <= 16) {
                        const cols = try arena.alloc([4]f32, v.array.items.len);
                        var ok = true;
                        for (v.array.items, 0..) |cv, ci| {
                            if (!readVec4(cv, &cols[ci])) ok = false;
                        }
                        if (ok) field.colliders = cols else try diags.add(path.slice(), "particles colliders must be arrays of [x, y, z, radius]", .{});
                    } else try diags.add(path.slice(), "particles colliders must be an array of up to 16 spheres", .{});
                }
                if (getField(pv.object, "box_colliders")) |v| {
                    if (v == .array and v.array.items.len <= 16) {
                        const boxes = try arena.alloc([6]f32, v.array.items.len);
                        var ok = true;
                        for (v.array.items, 0..) |bv, bi| {
                            if (!readVec6(bv, &boxes[bi])) ok = false;
                        }
                        if (ok) field.box_colliders = boxes else try diags.add(path.slice(), "particles box_colliders must be arrays of [x, y, z, hx, hy, hz]", .{});
                    } else try diags.add(path.slice(), "particles box_colliders must be an array of up to 16 boxes", .{});
                }
                if (getField(pv.object, "plane_colliders")) |v| {
                    if (v == .array and v.array.items.len <= 16) {
                        const planes = try arena.alloc([4]f32, v.array.items.len);
                        var ok = true;
                        for (v.array.items, 0..) |pcv, pi| {
                            if (!readVec4(pcv, &planes[pi])) ok = false;
                        }
                        if (ok) field.plane_colliders = planes else try diags.add(path.slice(), "particles plane_colliders must be arrays of [nx, ny, nz, d]", .{});
                    } else try diags.add(path.slice(), "particles plane_colliders must be an array of up to 16 planes", .{});
                }
                if (getField(pv.object, "mesh")) |v| {
                    if (v == .bool) field.mesh = v.bool;
                }
                if (getField(pv.object, "mesh_shape")) |v| {
                    if (try expectString(diags, path, v)) |sname| {
                        if (std.mem.eql(u8, sname, "octahedron") or std.mem.eql(u8, sname, "cube") or std.mem.eql(u8, sname, "tetra")) {
                            field.mesh_shape = try arena.dupe(u8, sname);
                        } else try diags.add(path.slice(), "particles mesh_shape must be octahedron, cube, or tetra", .{});
                    }
                }
                if (getField(pv.object, "sub_count")) |v| {
                    if (v == .integer and v.integer >= 0 and v.integer <= 64) field.sub_count = @intCast(v.integer) else {
                        try diags.add(path.slice(), "particles sub_count must be an integer 0..64", .{});
                    }
                }
                if (getField(pv.object, "sub_speed")) |v| field.sub_speed = @floatCast(numberOf(v) orelse field.sub_speed);
                if (getField(pv.object, "sub_lifetime")) |v| field.sub_lifetime = @floatCast(numberOf(v) orelse field.sub_lifetime);
                if (getField(pv.object, "gpu")) |v| {
                    if (v == .bool) field.gpu = v.bool;
                }
                if (getField(pv.object, "sph")) |v| {
                    if (v == .bool) field.sph = v.bool;
                }
                if (getField(pv.object, "instanced")) |v| {
                    if (v == .bool) field.instanced = v.bool;
                }
                particle_field = field;
            }
            path.pop(pmark);
        }
        var grade_field: ?GradeField = null;
        if (getField(object, "grade")) |gv| {
            const gmark = path.push("grade");
            if (!std.mem.eql(u8, node_type, "grade.pass")) {
                try diags.add(path.slice(), "grade is a grade.pass field, found it on '{s}'", .{node_type});
            } else if (gv != .object) {
                try diags.add(path.slice(), "grade must be an object", .{});
            } else {
                var field: GradeField = .{};
                if (getField(gv.object, "exposure")) |v| field.exposure = @floatCast(numberOf(v) orelse field.exposure);
                if (getField(gv.object, "contrast")) |v| field.contrast = @floatCast(numberOf(v) orelse field.contrast);
                if (getField(gv.object, "saturation")) |v| field.saturation = @floatCast(numberOf(v) orelse field.saturation);
                if (getField(gv.object, "temperature")) |v| field.temperature = @floatCast(numberOf(v) orelse field.temperature);
                if (getField(gv.object, "brightness")) |v| field.brightness = @floatCast(numberOf(v) orelse field.brightness);
                if (getField(gv.object, "hue")) |v| field.hue = @floatCast(numberOf(v) orelse field.hue);
                if (getField(gv.object, "tint")) |v| field.tint = @floatCast(numberOf(v) orelse field.tint);
                if (getField(gv.object, "grayscale")) |v| field.grayscale = @floatCast(numberOf(v) orelse field.grayscale);
                if (getField(gv.object, "invert")) |v| field.invert = @floatCast(numberOf(v) orelse field.invert);
                if (getField(gv.object, "posterize")) |v| field.posterize = @floatCast(numberOf(v) orelse field.posterize);
                if (getField(gv.object, "mask")) |v| {
                    if (v == .string) {
                        if (maskChannelIndex(v.string)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "grade mask names an unknown channel '{s}'", .{v.string});
                    }
                }
                grade_field = field;
            }
            path.pop(gmark);
        }
        var dehaze_field: ?DehazeField = null;
        if (getField(object, "dehaze")) |dv| {
            const dmark = path.push("dehaze");
            if (!std.mem.eql(u8, node_type, "dehaze.pass")) {
                try diags.add(path.slice(), "dehaze is a dehaze.pass field, found it on '{s}'", .{node_type});
            } else if (dv != .object) {
                try diags.add(path.slice(), "dehaze must be an object", .{});
            } else {
                var field: DehazeField = .{};
                if (getField(dv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
                dehaze_field = field;
            }
            path.pop(dmark);
        }
        var relight_field: ?RelightField = null;
        if (getField(object, "relight")) |rv| {
            const rmark = path.push("relight");
            if (!std.mem.eql(u8, node_type, "relight.pass")) {
                try diags.add(path.slice(), "relight is a relight.pass field, found it on '{s}'", .{node_type});
            } else if (rv != .object) {
                try diags.add(path.slice(), "relight must be an object", .{});
            } else {
                var field: RelightField = .{};
                if (getField(rv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
                if (getField(rv.object, "angle")) |v| field.angle = @floatCast(numberOf(v) orelse field.angle);
                relight_field = field;
            }
            path.pop(rmark);
        }
        var glare_field: ?GlareField = null;
        if (getField(object, "glare")) |gv| {
            const glmark = path.push("glare");
            if (!std.mem.eql(u8, node_type, "glare.pass")) {
                try diags.add(path.slice(), "glare is a glare.pass field, found it on '{s}'", .{node_type});
            } else if (gv != .object) {
                try diags.add(path.slice(), "glare must be an object", .{});
            } else {
                var field: GlareField = .{};
                if (getField(gv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
                if (getField(gv.object, "threshold")) |v| field.threshold = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.threshold)), 0, 1);
                glare_field = field;
            }
            path.pop(glmark);
        }
        var vignette_field: ?VignetteField = null;
        if (getField(object, "vignette")) |vv| {
            const vmark = path.push("vignette");
            if (!std.mem.eql(u8, node_type, "vignette.pass")) {
                try diags.add(path.slice(), "vignette is a vignette.pass field, found it on '{s}'", .{node_type});
            } else if (vv != .object) {
                try diags.add(path.slice(), "vignette must be an object", .{});
            } else {
                var field: VignetteField = .{};
                if (getField(vv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), -1, 1);
                if (getField(vv.object, "radius")) |v| field.radius = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.radius)), 0, 0.99);
                vignette_field = field;
            }
            path.pop(vmark);
        }
        var lowlight_field: ?LowLightField = null;
        if (getField(object, "lowlight")) |lv| {
            const lmark = path.push("lowlight");
            if (!std.mem.eql(u8, node_type, "lowlight.pass")) {
                try diags.add(path.slice(), "lowlight is a lowlight.pass field, found it on '{s}'", .{node_type});
            } else if (lv != .object) {
                try diags.add(path.slice(), "lowlight must be an object", .{});
            } else {
                var field: LowLightField = .{};
                if (getField(lv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
                if (getField(lv.object, "denoise")) |v| field.denoise = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.denoise)), 0, 1);
                lowlight_field = field;
            }
            path.pop(lmark);
        }
        var undistort_field: ?UndistortField = null;
        if (getField(object, "undistort")) |uv| {
            const umark = path.push("undistort");
            if (!std.mem.eql(u8, node_type, "undistort.pass")) {
                try diags.add(path.slice(), "undistort is an undistort.pass field, found it on '{s}'", .{node_type});
            } else if (uv != .object) {
                try diags.add(path.slice(), "undistort must be an object", .{});
            } else {
                var field: UndistortField = .{};
                if (getField(uv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
                undistort_field = field;
            }
            path.pop(umark);
        }
        var material_field: ?material.Graph = null;
        if (getField(object, "material")) |mv| {
            const mmark = path.push("material");
            if (!std.mem.eql(u8, node_type, "shader.pass")) {
                try diags.add(path.slice(), "material is a shader.pass field, found it on '{s}'", .{node_type});
            } else {
                const graph: ?material.Graph = material.parse(arena, mv) catch |err| blk: {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    try diags.add(path.slice(), "material graph is malformed ({s})", .{@errorName(err)});
                    break :blk null;
                };
                if (graph) |g| {
                    const types = try arena.alloc(material.ValueType, g.nodes.len);
                    material.validate(arena, g, types) catch |err| {
                        if (err == error.OutOfMemory) return error.OutOfMemory;
                        try diags.add(path.slice(), "material graph is invalid ({s})", .{@errorName(err)});
                    };
                    material_field = g;
                }
            }
            path.pop(mmark);
        }
        var bloom_field: ?BloomField = null;
        if (getField(object, "bloom")) |bv| {
            const bmark = path.push("bloom");
            if (!std.mem.eql(u8, node_type, "bloom.pass")) {
                try diags.add(path.slice(), "bloom is a bloom.pass field, found it on '{s}'", .{node_type});
            } else if (bv != .object) {
                try diags.add(path.slice(), "bloom must be an object", .{});
            } else {
                var field: BloomField = .{};
                if (getField(bv.object, "threshold")) |v| field.threshold = @floatCast(numberOf(v) orelse field.threshold);
                if (getField(bv.object, "intensity")) |v| field.intensity = @floatCast(numberOf(v) orelse field.intensity);
                bloom_field = field;
            }
            path.pop(bmark);
        }
        var dof_field: ?DofField = null;
        if (getField(object, "dof")) |dv| {
            const dmark = path.push("dof");
            if (!std.mem.eql(u8, node_type, "dof.pass")) {
                try diags.add(path.slice(), "dof is a dof.pass field, found it on '{s}'", .{node_type});
            } else if (dv != .object) {
                try diags.add(path.slice(), "dof must be an object", .{});
            } else {
                var field: DofField = .{};
                if (getField(dv.object, "focus")) |v| field.focus = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.focus)), 0.0, 1.0);
                if (getField(dv.object, "strength")) |v| field.strength = @floatCast(numberOf(v) orelse field.strength);
                dof_field = field;
            }
            path.pop(dmark);
        } else if (std.mem.eql(u8, node_type, "dof.pass")) {
            dof_field = .{};
        }
        var fog_field: ?FogField = null;
        if (getField(object, "fog")) |fv| {
            const fmark = path.push("fog");
            if (!std.mem.eql(u8, node_type, "fog.pass")) {
                try diags.add(path.slice(), "fog is a fog.pass field, found it on '{s}'", .{node_type});
            } else if (fv != .object) {
                try diags.add(path.slice(), "fog must be an object", .{});
            } else {
                var field: FogField = .{};
                if (getField(fv.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "fog color must be three numbers", .{});
                }
                if (getField(fv.object, "density")) |v| field.density = @floatCast(numberOf(v) orelse field.density);
                fog_field = field;
            }
            path.pop(fmark);
        } else if (std.mem.eql(u8, node_type, "fog.pass")) {
            fog_field = .{};
        }
        var outline_field: ?OutlineField = null;
        if (getField(object, "outline")) |ov| {
            const omark = path.push("outline");
            if (!std.mem.eql(u8, node_type, "outline.pass")) {
                try diags.add(path.slice(), "outline is an outline.pass field, found it on '{s}'", .{node_type});
            } else if (ov != .object) {
                try diags.add(path.slice(), "outline must be an object", .{});
            } else {
                var field: OutlineField = .{};
                if (getField(ov.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "outline color must be three numbers", .{});
                }
                if (getField(ov.object, "threshold")) |v| field.threshold = @floatCast(numberOf(v) orelse field.threshold);
                if (getField(ov.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "outline mask names an unknown channel '{s}'", .{name});
                    }
                }
                outline_field = field;
            }
            path.pop(omark);
        } else if (std.mem.eql(u8, node_type, "outline.pass")) {
            outline_field = .{};
        }
        var occluder_field: ?OccluderField = null;
        if (getField(object, "occluder")) |ov| {
            const omark = path.push("occluder");
            if (!std.mem.eql(u8, node_type, "occluder.pass")) {
                try diags.add(path.slice(), "occluder is an occluder.pass field, found it on '{s}'", .{node_type});
            } else if (ov != .object) {
                try diags.add(path.slice(), "occluder must be an object", .{});
            } else {
                var field: OccluderField = .{};
                if (getField(ov.object, "expand")) |v| field.expand = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.expand)), 0.0, 0.2);
                if (getField(ov.object, "softness")) |v| field.softness = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.softness)), 0.0, 0.5);
                if (getField(ov.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "occluder mask names an unknown channel '{s}'", .{name});
                    }
                }
                occluder_field = field;
            }
            path.pop(omark);
        } else if (std.mem.eql(u8, node_type, "occluder.pass")) {
            occluder_field = .{};
        }
        var cutout_field: ?CutoutField = null;
        if (getField(object, "cutout")) |cv| {
            const cmark = path.push("cutout");
            if (!std.mem.eql(u8, node_type, "cutout.pass")) {
                try diags.add(path.slice(), "cutout is a cutout.pass field, found it on '{s}'", .{node_type});
            } else if (cv != .object) {
                try diags.add(path.slice(), "cutout must be an object", .{});
            } else {
                var field: CutoutField = .{};
                if (getField(cv.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "cutout color must be three numbers", .{});
                }
                if (getField(cv.object, "softness")) |v| field.softness = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.softness)), 0.0, 0.5);
                if (getField(cv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "cutout mask names an unknown channel '{s}'", .{name});
                    }
                }
                cutout_field = field;
            }
            path.pop(cmark);
        } else if (std.mem.eql(u8, node_type, "cutout.pass")) {
            cutout_field = .{};
        }
        var tint_field: ?TintField = null;
        if (getField(object, "tint")) |tv| {
            const tintmark = path.push("tint");
            if (!std.mem.eql(u8, node_type, "tint.pass")) {
                try diags.add(path.slice(), "tint is a tint.pass field, found it on '{s}'", .{node_type});
            } else if (tv != .object) {
                try diags.add(path.slice(), "tint must be an object", .{});
            } else {
                var field: TintField = .{};
                if (getField(tv.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "tint color must be three numbers", .{});
                }
                if (getField(tv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(tv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "tint mask names an unknown channel '{s}'", .{name});
                    }
                }
                if (getField(tv.object, "source")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.mem.eql(u8, name, "reference")) {
                            field.from_reference = true;
                        } else if (!std.mem.eql(u8, name, "static")) {
                            try diags.add(path.slice(), "tint source must be reference or static", .{});
                        }
                    }
                }
                if (getField(tv.object, "blend")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(TintBlend, name)) |mode| field.blend = mode else try diags.add(path.slice(), "tint blend must be normal, multiply, or screen", .{});
                    }
                }
                if (getField(tv.object, "finish")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.mem.eql(u8, name, "none")) {
                            field.finish = .matte;
                        } else if (std.meta.stringToEnum(TintFinish, name)) |mode| {
                            field.finish = mode;
                        } else try diags.add(path.slice(), "tint finish must be matte, gloss, shimmer, or metallic", .{});
                    }
                }
                tint_field = field;
            }
            path.pop(tintmark);
        } else if (std.mem.eql(u8, node_type, "tint.pass")) {
            tint_field = .{};
        }
        var smooth_field: ?SmoothField = null;
        if (getField(object, "smooth")) |sv| {
            const smoothmark = path.push("smooth");
            if (!std.mem.eql(u8, node_type, "smooth.pass")) {
                try diags.add(path.slice(), "smooth is a smooth.pass field, found it on '{s}'", .{node_type});
            } else if (sv != .object) {
                try diags.add(path.slice(), "smooth must be an object", .{});
            } else {
                var field: SmoothField = .{};
                if (getField(sv.object, "amount")) |v| field.amount = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.amount)), -1.0, 1.0);
                if (getField(sv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "smooth mask names an unknown channel '{s}'", .{name});
                    }
                }
                smooth_field = field;
            }
            path.pop(smoothmark);
        } else if (std.mem.eql(u8, node_type, "smooth.pass")) {
            smooth_field = .{};
        }
        var paint_field: ?PaintField = null;
        if (getField(object, "paint")) |pv| {
            const paintmark = path.push("paint");
            if (!std.mem.eql(u8, node_type, "paint.face")) {
                try diags.add(path.slice(), "paint is a paint.face field, found it on '{s}'", .{node_type});
            } else if (pv != .object) {
                try diags.add(path.slice(), "paint must be an object", .{});
            } else {
                var field: PaintField = .{};
                if (getField(pv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(pv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "paint mask names an unknown channel '{s}'", .{name});
                    }
                }
                if (getField(pv.object, "blend")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(TintBlend, name)) |mode| field.blend = mode else try diags.add(path.slice(), "paint blend must be normal, multiply, or screen", .{});
                    }
                }
                paint_field = field;
            }
            path.pop(paintmark);
        } else if (std.mem.eql(u8, node_type, "paint.face")) {
            paint_field = .{};
        }
        var swap_field: ?SwapField = null;
        if (getField(object, "swap")) |sv| {
            const swapmark = path.push("swap");
            if (!std.mem.eql(u8, node_type, "face.swap")) {
                try diags.add(path.slice(), "swap is a face.swap field, found it on '{s}'", .{node_type});
            } else if (sv != .object) {
                try diags.add(path.slice(), "swap must be an object", .{});
            } else {
                var field: SwapField = .{};
                if (getField(sv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(sv.object, "feather")) |v| field.feather = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.feather)), 0.02, 1.0);
                if (getField(sv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "swap mask names an unknown channel '{s}'", .{name});
                    }
                }
                swap_field = field;
            }
            path.pop(swapmark);
        } else if (std.mem.eql(u8, node_type, "face.swap")) {
            swap_field = .{};
        }
        var lash_field: ?LashField = null;
        if (getField(object, "lashes")) |lv| {
            const lashmark = path.push("lashes");
            if (!std.mem.eql(u8, node_type, "mesh.lashes")) {
                try diags.add(path.slice(), "lashes is a mesh.lashes field, found it on '{s}'", .{node_type});
            } else if (lv != .object) {
                try diags.add(path.slice(), "lashes must be an object", .{});
            } else {
                var field: LashField = .{};
                if (getField(lv.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "lashes color must be three numbers", .{});
                }
                if (getField(lv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(lv.object, "length")) |v| field.length = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.length)), 0.0, 2.0);
                if (getField(lv.object, "curl")) |v| field.curl = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.curl)), -1.0, 1.0);
                lash_field = field;
            }
            path.pop(lashmark);
        } else if (std.mem.eql(u8, node_type, "mesh.lashes")) {
            lash_field = .{};
        }
        var retouch_field: ?RetouchField = null;
        if (getField(object, "retouch")) |rv| {
            const retouchmark = path.push("retouch");
            if (!std.mem.eql(u8, node_type, "retouch.pass")) {
                try diags.add(path.slice(), "retouch is a retouch.pass field, found it on '{s}'", .{node_type});
            } else if (rv != .object) {
                try diags.add(path.slice(), "retouch must be an object", .{});
            } else {
                var field: RetouchField = .{};
                if (getField(rv.object, "mode")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(@TypeOf(field.mode), name)) |m| field.mode = m else try diags.add(path.slice(), "retouch mode must be blemish or shine", .{});
                    }
                }
                if (getField(rv.object, "amount")) |v| field.amount = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.amount)), 0.0, 1.0);
                if (getField(rv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "retouch mask names an unknown channel '{s}'", .{name});
                    }
                }
                retouch_field = field;
            }
            path.pop(retouchmark);
        } else if (std.mem.eql(u8, node_type, "retouch.pass")) {
            retouch_field = .{};
        }
        var matte_field: ?MatteField = null;
        if (getField(object, "matte")) |mv| {
            const mattemark = path.push("matte");
            if (!std.mem.eql(u8, node_type, "matte.refine")) {
                try diags.add(path.slice(), "matte is a matte.refine field, found it on '{s}'", .{node_type});
            } else if (mv != .object) {
                try diags.add(path.slice(), "matte must be an object", .{});
            } else {
                var field: MatteField = .{};
                if (getField(mv.object, "radius")) |v| field.radius = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.radius)), 0.5, 6.0);
                if (getField(mv.object, "sensitivity")) |v| field.sensitivity = @max(0.0, @as(f32, @floatCast(numberOf(v) orelse field.sensitivity)));
                if (getField(mv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0.0, 1.0);
                if (getField(mv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "matte mask names an unknown channel '{s}'", .{name});
                    }
                }
                matte_field = field;
            }
            path.pop(mattemark);
        } else if (std.mem.eql(u8, node_type, "matte.refine")) {
            matte_field = .{};
        }
        var hair_matte_field: ?HairMatteField = null;
        if (getField(object, "hair_matte")) |hv| {
            const hairmark = path.push("hair_matte");
            if (!std.mem.eql(u8, node_type, "matte.hair")) {
                try diags.add(path.slice(), "hair_matte is a matte.hair field, found it on '{s}'", .{node_type});
            } else if (hv != .object) {
                try diags.add(path.slice(), "hair_matte must be an object", .{});
            } else {
                var field: HairMatteField = .{};
                if (getField(hv.object, "radius")) |v| field.radius = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.radius)), 0.5, 6.0);
                if (getField(hv.object, "sensitivity")) |v| field.sensitivity = @max(0.0, @as(f32, @floatCast(numberOf(v) orelse field.sensitivity)));
                if (getField(hv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0.0, 1.0);
                hair_matte_field = field;
            }
            path.pop(hairmark);
        } else if (std.mem.eql(u8, node_type, "matte.hair")) {
            hair_matte_field = .{};
        }
        var stylize_field: ?StylizeField = null;
        if (getField(object, "stylize")) |yv| {
            const ymark = path.push("stylize");
            if (!std.mem.eql(u8, node_type, "stylize.pass")) {
                try diags.add(path.slice(), "stylize is a stylize.pass field, found it on '{s}'", .{node_type});
            } else if (yv != .object) {
                try diags.add(path.slice(), "stylize must be an object", .{});
            } else {
                var field: StylizeField = .{};
                if (getField(yv.object, "mode")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(@TypeOf(field.mode), name)) |m| field.mode = m else try diags.add(path.slice(), "stylize mode names an unknown filter '{s}'", .{name});
                    }
                }
                if (getField(yv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0.0, 4.0);
                if (getField(yv.object, "threshold")) |v| field.threshold = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.threshold)), 0.0, 1.0);
                if (getField(yv.object, "levels")) |v| field.levels = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.levels)), 1.0, 256.0);
                stylize_field = field;
            }
            path.pop(ymark);
        } else if (std.mem.eql(u8, node_type, "stylize.pass")) {
            stylize_field = .{};
        }
        var edge_field: ?EdgeField = null;
        if (getField(object, "edge")) |ev| {
            const emark = path.push("edge");
            if (!std.mem.eql(u8, node_type, "edge.pass")) {
                try diags.add(path.slice(), "edge is an edge.pass field, found it on '{s}'", .{node_type});
            } else if (ev != .object) {
                try diags.add(path.slice(), "edge must be an object", .{});
            } else {
                var field: EdgeField = .{};
                if (getField(ev.object, "mode")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(@TypeOf(field.mode), name)) |m| field.mode = m else try diags.add(path.slice(), "edge mode names an unknown detector '{s}'", .{name});
                    }
                }
                if (getField(ev.object, "low_threshold")) |v| field.low_threshold = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.low_threshold)), 0.0, 1.0);
                if (getField(ev.object, "high_threshold")) |v| field.high_threshold = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.high_threshold)), 0.0, 1.0);
                if (getField(ev.object, "blur_radius")) |v| field.blur_radius = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.blur_radius)), 1.0, 8.0);
                if (getField(ev.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0.0, 8.0);
                if (getField(ev.object, "invert")) |v| {
                    if (v == .bool) field.invert = v.bool;
                }
                edge_field = field;
            }
            path.pop(emark);
        } else if (std.mem.eql(u8, node_type, "edge.pass")) {
            edge_field = .{};
        }
        var warp_field: ?WarpField = null;
        if (getField(object, "warp")) |wv| {
            const wmark = path.push("warp");
            if (!std.mem.eql(u8, node_type, "warp.pass")) {
                try diags.add(path.slice(), "warp is a warp.pass field, found it on '{s}'", .{node_type});
            } else if (wv != .object) {
                try diags.add(path.slice(), "warp must be an object", .{});
            } else {
                var field: WarpField = .{};
                if (getField(wv.object, "mode")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.meta.stringToEnum(@TypeOf(field.mode), name)) |m| field.mode = m else try diags.add(path.slice(), "warp mode names an unknown distortion '{s}'", .{name});
                    }
                }
                if (getField(wv.object, "center_x")) |v| field.center_x = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.center_x)), 0.0, 1.0);
                if (getField(wv.object, "center_y")) |v| field.center_y = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.center_y)), 0.0, 1.0);
                if (getField(wv.object, "radius")) |v| field.radius = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.radius)), 0.01, 1.0);
                // face_scale reads strength as a signed scale, so it allows a
                // negative shrink; every other mode keeps the positive range.
                if (getField(wv.object, "strength")) |v| {
                    const lo: f32 = if (field.mode == .face_scale) -4.0 else 0.0;
                    field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), lo, 4.0);
                }
                if (getField(wv.object, "refractive_index")) |v| field.refractive_index = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.refractive_index)), 0.1, 1.0);
                if (getField(wv.object, "aspect_auto")) |v| {
                    if (v == .bool) field.aspect_auto = v.bool;
                }
                if (getField(wv.object, "symmetry")) |v| {
                    if (v == .bool) field.symmetry = v.bool;
                }
                if (getField(wv.object, "symmetry_x")) |v| field.symmetry_x = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.symmetry_x)), 0.0, 1.0);
                if (getField(wv.object, "points")) |v| {
                    if (v == .array and v.array.items.len <= warp_point_max) {
                        var n: usize = 0;
                        for (v.array.items) |pv| {
                            if (pv != .object) {
                                try diags.add(path.slice(), "each warp point must be an object", .{});
                                continue;
                            }
                            var p: LiquifyPoint = .{};
                            if (getField(pv.object, "x")) |xv| p.x = std.math.clamp(@as(f32, @floatCast(numberOf(xv) orelse p.x)), 0.0, 1.0);
                            if (getField(pv.object, "y")) |yv| p.y = std.math.clamp(@as(f32, @floatCast(numberOf(yv) orelse p.y)), 0.0, 1.0);
                            if (getField(pv.object, "dx")) |dxv| p.dx = std.math.clamp(@as(f32, @floatCast(numberOf(dxv) orelse p.dx)), -1.0, 1.0);
                            if (getField(pv.object, "dy")) |dyv| p.dy = std.math.clamp(@as(f32, @floatCast(numberOf(dyv) orelse p.dy)), -1.0, 1.0);
                            if (getField(pv.object, "radius")) |rv| p.radius = std.math.clamp(@as(f32, @floatCast(numberOf(rv) orelse p.radius)), 0.01, 1.0);
                            field.points[n] = p;
                            n += 1;
                        }
                        field.point_count = n;
                    } else try diags.add(path.slice(), "warp points must be an array of up to eight push points", .{});
                }
                if (getField(wv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "warp mask names an unknown channel '{s}'", .{name});
                    }
                }
                warp_field = field;
            }
            path.pop(wmark);
        } else if (std.mem.eql(u8, node_type, "warp.pass")) {
            warp_field = .{};
        }
        var reshape_field: ?ReshapeField = null;
        if (getField(object, "reshape")) |rv| {
            const rmark = path.push("reshape");
            if (!std.mem.eql(u8, node_type, "reshape.bank")) {
                try diags.add(path.slice(), "reshape is a reshape.bank field, found it on '{s}'", .{node_type});
            } else if (rv != .object) {
                try diags.add(path.slice(), "reshape must be an object", .{});
            } else {
                var field: ReshapeField = .{};
                inline for (std.meta.fields(ReshapeField)) |f| {
                    if (getField(rv.object, f.name)) |v| {
                        @field(field, f.name) = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse @field(field, f.name))), -1.0, 1.0);
                    }
                }
                reshape_field = field;
            }
            path.pop(rmark);
        } else if (std.mem.eql(u8, node_type, "reshape.bank")) {
            reshape_field = .{};
        }
        var trail_field: ?TrailField = null;
        if (getField(object, "trail")) |tv| {
            const tmark = path.push("trail");
            if (!std.mem.eql(u8, node_type, "trail.pass")) {
                try diags.add(path.slice(), "trail is a trail.pass field, found it on '{s}'", .{node_type});
            } else if (tv != .object) {
                try diags.add(path.slice(), "trail must be an object", .{});
            } else {
                var field: TrailField = .{};
                if (getField(tv.object, "amount")) |v| field.amount = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.amount)), 0.0, 1.0);
                trail_field = field;
            }
            path.pop(tmark);
        } else if (std.mem.eql(u8, node_type, "trail.pass")) {
            trail_field = .{};
        }
        var ssr_field: ?SsrField = null;
        if (getField(object, "ssr")) |rv| {
            const rmark = path.push("ssr");
            if (!std.mem.eql(u8, node_type, "ssr.pass")) {
                try diags.add(path.slice(), "ssr is an ssr.pass field, found it on '{s}'", .{node_type});
            } else if (rv != .object) {
                try diags.add(path.slice(), "ssr must be an object", .{});
            } else {
                var field: SsrField = .{};
                if (getField(rv.object, "strength")) |v| field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0.0, 1.0);
                if (getField(rv.object, "plane")) |v| field.plane = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.plane)), 0.0, 1.0);
                ssr_field = field;
            }
            path.pop(rmark);
        } else if (std.mem.eql(u8, node_type, "ssr.pass")) {
            ssr_field = .{};
        }
        var env_field: ?EnvField = null;
        if (getField(object, "env")) |ev| {
            const emark = path.push("env");
            if (!std.mem.eql(u8, node_type, "env.pass")) {
                try diags.add(path.slice(), "env is an env.pass field, found it on '{s}'", .{node_type});
            } else if (ev != .object) {
                try diags.add(path.slice(), "env must be an object", .{});
            } else {
                var field: EnvField = .{};
                if (getField(ev.object, "top")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.top_r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.top_g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.top_b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "env top must be three numbers", .{});
                }
                if (getField(ev.object, "bottom")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.bottom_r = std.math.clamp(rgb[0], 0.0, 1.0);
                        field.bottom_g = std.math.clamp(rgb[1], 0.0, 1.0);
                        field.bottom_b = std.math.clamp(rgb[2], 0.0, 1.0);
                    } else try diags.add(path.slice(), "env bottom must be three numbers", .{});
                }
                if (getField(ev.object, "intensity")) |v| field.intensity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.intensity)), 0.0, 2.0);
                env_field = field;
            }
            path.pop(emark);
        } else if (std.mem.eql(u8, node_type, "env.pass")) {
            env_field = .{};
        }
        var sprite_field: ?SpriteField = null;
        if (getField(object, "sprite")) |sv| {
            const smark = path.push("sprite");
            if (!std.mem.eql(u8, node_type, "sprite.2d")) {
                try diags.add(path.slice(), "sprite is a sprite.2d field, found it on '{s}'", .{node_type});
            } else if (sv != .object) {
                try diags.add(path.slice(), "sprite must be an object", .{});
            } else {
                var field: SpriteField = .{};
                if (getField(sv.object, "x")) |v| field.x = @floatCast(numberOf(v) orelse field.x);
                if (getField(sv.object, "y")) |v| field.y = @floatCast(numberOf(v) orelse field.y);
                if (getField(sv.object, "w")) |v| field.w = @floatCast(numberOf(v) orelse field.w);
                if (getField(sv.object, "h")) |v| field.h = @floatCast(numberOf(v) orelse field.h);
                if (getField(sv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(sv.object, "opacity_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.opacity_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "x_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.x_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "y_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.y_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "w_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.w_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "h_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.h_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "frames")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= max_sprite_frames) {
                        field.frames = @intCast(v.integer);
                    } else try diags.add(path.slice(), "sprite frames must be an integer 1..{d}", .{max_sprite_frames});
                }
                if (getField(sv.object, "fps")) |v| field.fps = @floatCast(numberOf(v) orelse field.fps);
                if (getField(sv.object, "mask")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (maskChannelIndex(name)) |channel| field.mask_channel = channel else try diags.add(path.slice(), "sprite mask names an unknown channel '{s}'", .{name});
                    }
                }
                if (getField(sv.object, "mask_mode")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        if (std.mem.eql(u8, name, "behind")) field.mask_mode = .behind else if (std.mem.eql(u8, name, "over")) field.mask_mode = .over else try diags.add(path.slice(), "sprite mask_mode is 'behind' or 'over', found '{s}'", .{name});
                    }
                }
                if (getField(sv.object, "mask_strength")) |v| field.mask_strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.mask_strength)), 0.0, 1.0);
                if (getField(sv.object, "mask_strength_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.mask_strength_param = try arena.dupe(u8, s);
                }
                if (getField(sv.object, "interaction")) |iv| {
                    if (iv == .object) {
                        var it: Interaction = .{};
                        if (getField(iv.object, "drag")) |b| {
                            if (b == .bool) it.drag = b.bool;
                        }
                        if (getField(iv.object, "pinch")) |b| {
                            if (b == .bool) it.pinch = b.bool;
                        }
                        if (getField(iv.object, "rotate")) |b| {
                            if (b == .bool) it.rotate = b.bool;
                        }
                        if (getField(iv.object, "tap_event")) |v| {
                            if (try expectString(diags, path, v)) |s| it.tap_event = try arena.dupe(u8, s);
                        }
                        if (getField(iv.object, "slider_param")) |v| {
                            if (try expectString(diags, path, v)) |s| it.slider_param = try arena.dupe(u8, s);
                        }
                        if (getField(iv.object, "slider_vertical")) |b| {
                            if (b == .bool) it.slider_vertical = b.bool;
                        }
                        if (getField(iv.object, "slider_min")) |v| it.slider_min = @floatCast(numberOf(v) orelse it.slider_min);
                        if (getField(iv.object, "slider_max")) |v| it.slider_max = @floatCast(numberOf(v) orelse it.slider_max);
                        if (getField(iv.object, "carousel_param")) |v| {
                            if (try expectString(diags, path, v)) |s| it.carousel_param = try arena.dupe(u8, s);
                        }
                        if (getField(iv.object, "carousel_count")) |v| {
                            if (v == .integer and v.integer >= 1) it.carousel_count = @intCast(v.integer);
                        }
                        field.interaction = it;
                    } else try diags.add(path.slice(), "sprite interaction must be an object", .{});
                }
                sprite_field = field;
            }
            path.pop(smark);
        } else if (std.mem.eql(u8, node_type, "sprite.2d")) {
            // A sprite.2d node with no sprite block draws its image full-frame.
            sprite_field = .{};
        }
        var text_field: ?TextField = null;
        if (getField(object, "text")) |tv| {
            const tmark = path.push("text");
            if (!std.mem.eql(u8, node_type, "text.2d")) {
                try diags.add(path.slice(), "text is a text.2d field, found it on '{s}'", .{node_type});
            } else if (tv != .object) {
                try diags.add(path.slice(), "text must be an object", .{});
            } else {
                var field: TextField = .{};
                if (getField(tv.object, "content")) |v| {
                    if (try expectString(diags, path, v)) |s| field.content = try arena.dupe(u8, s);
                }
                if (getField(tv.object, "x")) |v| field.x = @floatCast(numberOf(v) orelse field.x);
                if (getField(tv.object, "y")) |v| field.y = @floatCast(numberOf(v) orelse field.y);
                if (getField(tv.object, "w")) |v| field.w = @floatCast(numberOf(v) orelse field.w);
                if (getField(tv.object, "h")) |v| field.h = @floatCast(numberOf(v) orelse field.h);
                if (getField(tv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(tv.object, "color")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.r = @intFromFloat(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0);
                        field.g = @intFromFloat(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0);
                        field.b = @intFromFloat(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0);
                    } else try diags.add(path.slice(), "text color must be three numbers", .{});
                }
                if (getField(tv.object, "opacity_param")) |v| {
                    if (try expectString(diags, path, v)) |s| field.opacity_param = try arena.dupe(u8, s);
                }
                if (getField(tv.object, "gradient")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.gradient = .{
                            @intFromFloat(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0),
                            @intFromFloat(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0),
                            @intFromFloat(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0),
                        };
                    } else try diags.add(path.slice(), "text gradient must be three numbers", .{});
                }
                if (getField(tv.object, "stroke")) |v| {
                    var rgb: [3]f32 = undefined;
                    if (readVec3(v, &rgb)) {
                        field.stroke = .{
                            @intFromFloat(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0),
                            @intFromFloat(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0),
                            @intFromFloat(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0),
                        };
                    } else try diags.add(path.slice(), "text stroke must be three numbers", .{});
                }
                if (getField(tv.object, "shadow")) |v| {
                    if (v == .bool) field.shadow = v.bool;
                }
                if (getField(tv.object, "depth")) |v| field.depth = @max(0.0, @as(f32, @floatCast(numberOf(v) orelse field.depth)));
                text_field = field;
            }
            path.pop(tmark);
        } else if (std.mem.eql(u8, node_type, "text.2d")) {
            try diags.add(path.slice(), "a text.2d node needs a text block", .{});
        }
        var video_field: ?VideoField = null;
        if (getField(object, "video")) |vv| {
            const vmark = path.push("video");
            if (!std.mem.eql(u8, node_type, "video.texture")) {
                try diags.add(path.slice(), "video is a video.texture field, found it on '{s}'", .{node_type});
            } else if (vv != .object) {
                try diags.add(path.slice(), "video must be an object", .{});
            } else {
                var field: VideoField = .{};
                if (getField(vv.object, "source")) |v| {
                    if (try expectString(diags, path, v)) |s| field.source = try arena.dupe(u8, s);
                }
                if (getField(vv.object, "x")) |v| field.x = @floatCast(numberOf(v) orelse field.x);
                if (getField(vv.object, "y")) |v| field.y = @floatCast(numberOf(v) orelse field.y);
                if (getField(vv.object, "w")) |v| field.w = @floatCast(numberOf(v) orelse field.w);
                if (getField(vv.object, "h")) |v| field.h = @floatCast(numberOf(v) orelse field.h);
                if (getField(vv.object, "opacity")) |v| field.opacity = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.opacity)), 0.0, 1.0);
                if (getField(vv.object, "fps")) |v| field.fps = @max(0.0, @as(f32, @floatCast(numberOf(v) orelse field.fps)));
                if (getField(vv.object, "loop")) |v| {
                    if (v == .bool) field.loop = v.bool;
                }
                if (field.source.len == 0) try diags.add(path.slice(), "a video.texture node needs a source", .{});
                video_field = field;
            }
            path.pop(vmark);
        } else if (std.mem.eql(u8, node_type, "video.texture")) {
            try diags.add(path.slice(), "a video.texture node needs a video block", .{});
        }
        var layout_field: ?LayoutField = null;
        if (getField(object, "layout")) |lv| {
            const lmark = path.push("layout");
            if (!std.mem.eql(u8, node_type, "layout.composite")) {
                try diags.add(path.slice(), "layout is a layout.composite field, found it on '{s}'", .{node_type});
            } else if (lv != .object) {
                try diags.add(path.slice(), "layout must be an object", .{});
            } else {
                var field: LayoutField = .{};
                if (getField(lv.object, "arrangement")) |v| {
                    if (v == .string) field.arrangement = arrangementValue(v.string);
                }
                if (getField(lv.object, "key")) |v| {
                    if (v == .string) field.key = keyModeValue(v.string);
                }
                if (getField(lv.object, "chroma")) |v| {
                    if (v == .array and v.array.items.len >= 3) {
                        field.chroma[0] = @floatCast(numberOf(v.array.items[0]) orelse 0);
                        field.chroma[1] = @floatCast(numberOf(v.array.items[1]) orelse 0);
                        field.chroma[2] = @floatCast(numberOf(v.array.items[2]) orelse 0);
                    }
                }
                if (getField(lv.object, "similarity")) |v| field.similarity = @floatCast(numberOf(v) orelse field.similarity);
                if (getField(lv.object, "opacity")) |v| field.opacity = @floatCast(numberOf(v) orelse field.opacity);
                layout_field = field;
            }
            path.pop(lmark);
        }
        if (getField(object, "hair")) |hair_value| {
            const hair_mark = path.push("hair");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "hair is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (hair_value != .object) {
                try diags.add(path.slice(), "hair must be an object", .{});
            } else {
                var field: HairField = .{ .strands = 24, .verts = 16, .length = 0.5 };
                if (getField(hair_value.object, "strands")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 256) field.strands = @intCast(v.integer);
                }
                if (getField(hair_value.object, "verts")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.verts = @intCast(v.integer);
                }
                if (getField(hair_value.object, "length")) |v| {
                    switch (v) {
                        .float => |f| field.length = @floatCast(f),
                        .integer => |n| field.length = @floatFromInt(n),
                        else => {},
                    }
                }
                hair_field = field;
            }
            path.pop(hair_mark);
        }
        var cloth_field: ?ClothField = null;
        if (getField(object, "cloth")) |cloth_value| {
            const cloth_mark = path.push("cloth");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "cloth is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (cloth_value != .object) {
                try diags.add(path.slice(), "cloth must be an object", .{});
            } else {
                var field: ClothField = .{ .cols = 8, .rows = 8, .width = 1.0, .height = 1.0 };
                var ok = true;
                if (getField(cloth_value.object, "cols")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.cols = @intCast(v.integer) else {
                        try diags.add(path.slice(), "cloth cols must be an integer 2..64", .{});
                        ok = false;
                    }
                }
                if (getField(cloth_value.object, "rows")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.rows = @intCast(v.integer) else {
                        try diags.add(path.slice(), "cloth rows must be an integer 2..64", .{});
                        ok = false;
                    }
                }
                if (getField(cloth_value.object, "width")) |v| {
                    switch (v) {
                        .float => |f| field.width = @floatCast(f),
                        .integer => |n| field.width = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "cloth width must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (getField(cloth_value.object, "height")) |v| {
                    switch (v) {
                        .float => |f| field.height = @floatCast(f),
                        .integer => |n| field.height = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "cloth height must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (ok) cloth_field = field;
            }
            path.pop(cloth_mark);
        }
        var balloon_field: ?BalloonField = null;
        if (getField(object, "balloon")) |balloon_value| {
            const balloon_mark = path.push("balloon");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "balloon is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (balloon_value != .object) {
                try diags.add(path.slice(), "balloon must be an object", .{});
            } else {
                var field: BalloonField = .{ .radius = 0.3, .subdivisions = 2, .pressure = 20.0 };
                var ok = true;
                if (getField(balloon_value.object, "pinned")) |v| {
                    if (v == .bool) field.pinned = v.bool else {
                        try diags.add(path.slice(), "balloon pinned must be a boolean", .{});
                        ok = false;
                    }
                }
                if (getField(balloon_value.object, "radius")) |v| {
                    switch (v) {
                        .float => |f| field.radius = @floatCast(f),
                        .integer => |n| field.radius = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "balloon radius must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (getField(balloon_value.object, "subdivisions")) |v| {
                    if (v == .integer and v.integer >= 0 and v.integer <= 3) field.subdivisions = @intCast(v.integer) else {
                        try diags.add(path.slice(), "balloon subdivisions must be an integer 0..3", .{});
                        ok = false;
                    }
                }
                if (getField(balloon_value.object, "pressure")) |v| {
                    switch (v) {
                        .float => |f| field.pressure = @floatCast(f),
                        .integer => |n| field.pressure = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "balloon pressure must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (ok) balloon_field = field;
            }
            path.pop(balloon_mark);
        }
        if (getField(object, "physics")) |physics_value| {
            const physics_mark = path.push("physics");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "physics is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (physics_value != .object) {
                try diags.add(path.slice(), "physics must be an object", .{});
            } else {
                var body: PhysicsBody = .{ .shape = .box, .size = .{ 0.1, 0.1, 0.1 }, .position = .{ 0, 0, 0 }, .dynamic = true };
                var shape_ok = false;
                if (getField(physics_value.object, "body")) |body_value| {
                    if (try expectString(diags, path, body_value)) |body_name| {
                        if (std.mem.eql(u8, body_name, "box")) {
                            body.shape = .box;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "sphere")) {
                            body.shape = .sphere;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "cylinder")) {
                            body.shape = .cylinder;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "capsule")) {
                            body.shape = .capsule;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "hull")) {
                            body.shape = .hull;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "mesh")) {
                            body.shape = .mesh;
                            shape_ok = true;
                        } else {
                            try diags.add(path.slice(), "unknown physics body '{s}'", .{body_name});
                        }
                    }
                } else {
                    try diags.add(path.slice(), "physics needs a body", .{});
                }
                if (getField(physics_value.object, "size")) |size_value| {
                    if (!readVec3(size_value, &body.size)) {
                        try diags.add(path.slice(), "physics size must be three numbers", .{});
                        shape_ok = false;
                    }
                }
                if (getField(physics_value.object, "points")) |points_value| {
                    if (points_value != .array or points_value.array.items.len < 4) {
                        try diags.add(path.slice(), "physics hull points must be an array of at least four [x, y, z]", .{});
                        shape_ok = false;
                    } else {
                        const pts = try arena.alloc([3]f32, points_value.array.items.len);
                        var pi: usize = 0;
                        var pts_ok = true;
                        for (points_value.array.items) |point_value| {
                            if (!readVec3(point_value, &pts[pi])) {
                                try diags.add(path.slice(), "physics hull point must be three numbers", .{});
                                pts_ok = false;
                                break;
                            }
                            pi += 1;
                        }
                        if (pts_ok) body.hull_points = pts else shape_ok = false;
                    }
                }
                if (getField(physics_value.object, "indices")) |indices_value| {
                    if (indices_value != .array or indices_value.array.items.len < 3 or indices_value.array.items.len % 3 != 0) {
                        try diags.add(path.slice(), "physics mesh indices must be a whole number of triangles (three per face)", .{});
                        shape_ok = false;
                    } else {
                        const idx = try arena.alloc(u32, indices_value.array.items.len);
                        var ii: usize = 0;
                        var idx_ok = true;
                        for (indices_value.array.items) |index_value| {
                            switch (index_value) {
                                .integer => |n| {
                                    if (n < 0 or n > std.math.maxInt(u32)) {
                                        idx_ok = false;
                                    } else {
                                        idx[ii] = @intCast(n);
                                    }
                                },
                                else => idx_ok = false,
                            }
                            if (!idx_ok) break;
                            ii += 1;
                        }
                        if (idx_ok) body.mesh_indices = idx else {
                            try diags.add(path.slice(), "physics mesh index must be a non-negative whole number", .{});
                            shape_ok = false;
                        }
                    }
                }
                if (getField(physics_value.object, "position")) |position_value| {
                    if (!readVec3(position_value, &body.position)) {
                        try diags.add(path.slice(), "physics position must be three numbers", .{});
                        shape_ok = false;
                    }
                }
                if (getField(physics_value.object, "rotation")) |rotation_value| {
                    if (!readVec3(rotation_value, &body.rotation)) {
                        try diags.add(path.slice(), "physics rotation must be three numbers (euler degrees)", .{});
                        shape_ok = false;
                    }
                }
                // A mesh body with no explicit points takes its collider from
                // the node's own decoded glb geometry.
                if (body.shape == .mesh and body.hull_points.len == 0) body.mesh_from_glb = true;
                if (getField(physics_value.object, "friction")) |friction_value| {
                    switch (friction_value) {
                        .float => |f| body.friction = @floatCast(f),
                        .integer => |n| body.friction = @floatFromInt(n),
                        else => try diags.add(path.slice(), "physics friction must be a number", .{}),
                    }
                }
                if (getField(physics_value.object, "restitution")) |restitution_value| {
                    switch (restitution_value) {
                        .float => |f| body.restitution = @floatCast(f),
                        .integer => |n| body.restitution = @floatFromInt(n),
                        else => try diags.add(path.slice(), "physics restitution must be a number", .{}),
                    }
                }
                if (getField(physics_value.object, "planar")) |planar_value| {
                    if (planar_value == .bool) body.planar = planar_value.bool else {
                        try diags.add(path.slice(), "physics planar must be a boolean", .{});
                    }
                }
                if (getField(physics_value.object, "follow")) |follow_value| {
                    if (try expectString(diags, path, follow_value)) |follow_name| {
                        if (std.mem.eql(u8, follow_name, "head")) {
                            body.follow = .head;
                            body.kinematic = true;
                        } else if (!std.mem.eql(u8, follow_name, "none")) {
                            try diags.add(path.slice(), "unknown physics follow '{s}'", .{follow_name});
                        }
                    }
                }
                if (getField(physics_value.object, "motion")) |motion_value| {
                    if (try expectString(diags, path, motion_value)) |motion_name| {
                        if (std.mem.eql(u8, motion_name, "static")) {
                            body.dynamic = false;
                        } else if (std.mem.eql(u8, motion_name, "dynamic")) {
                            body.dynamic = true;
                        } else if (std.mem.eql(u8, motion_name, "kinematic")) {
                            body.dynamic = false;
                            body.kinematic = true;
                        } else {
                            try diags.add(path.slice(), "unknown physics motion '{s}'", .{motion_name});
                        }
                    }
                }
                if (getField(physics_value.object, "chain")) |chain_value| {
                    if (chain_value != .object) {
                        try diags.add(path.slice(), "physics chain must be an object", .{});
                    } else {
                        if (getField(chain_value.object, "to")) |to_value| {
                            if (try expectString(diags, path, to_value)) |to_name| {
                                body.chain_to = try arena.dupe(u8, to_name);
                            }
                        } else {
                            try diags.add(path.slice(), "physics chain needs a to", .{});
                        }
                        if (getField(chain_value.object, "length")) |len_value| {
                            switch (len_value) {
                                .float => |f| body.chain_length = @floatCast(f),
                                .integer => |n| body.chain_length = @floatFromInt(n),
                                else => try diags.add(path.slice(), "physics chain length must be a number", .{}),
                            }
                        }
                        if (getField(chain_value.object, "joint")) |joint_value| {
                            if (try expectString(diags, path, joint_value)) |joint_name| {
                                if (std.mem.eql(u8, joint_name, "distance")) {
                                    body.joint = .distance;
                                } else if (std.mem.eql(u8, joint_name, "point")) {
                                    body.joint = .point;
                                } else if (std.mem.eql(u8, joint_name, "fixed")) {
                                    body.joint = .fixed;
                                } else if (std.mem.eql(u8, joint_name, "hinge")) {
                                    body.joint = .hinge;
                                } else if (std.mem.eql(u8, joint_name, "spring")) {
                                    body.joint = .spring;
                                } else {
                                    try diags.add(path.slice(), "physics chain joint must be distance, point, fixed, hinge, or spring", .{});
                                }
                            }
                        }
                        if (getField(chain_value.object, "jiggle")) |jiggle_value| {
                            if (jiggle_value != .object) {
                                try diags.add(path.slice(), "physics chain jiggle must be an object", .{});
                            } else {
                                if (getField(jiggle_value.object, "segments")) |seg_value| {
                                    switch (seg_value) {
                                        .integer => |n| body.jiggle_segments = if (n > 0) @intCast(@min(n, 128)) else 0,
                                        else => try diags.add(path.slice(), "physics chain jiggle segments must be a whole number", .{}),
                                    }
                                }
                                if (getField(jiggle_value.object, "stiffness")) |stiff_value| {
                                    switch (stiff_value) {
                                        .float => |f| body.jiggle_stiffness = @floatCast(f),
                                        .integer => |n| body.jiggle_stiffness = @floatFromInt(n),
                                        else => try diags.add(path.slice(), "physics chain jiggle stiffness must be a number", .{}),
                                    }
                                }
                                if (getField(jiggle_value.object, "damping")) |damp_value| {
                                    switch (damp_value) {
                                        .float => |f| body.jiggle_damping = @floatCast(f),
                                        .integer => |n| body.jiggle_damping = @floatFromInt(n),
                                        else => try diags.add(path.slice(), "physics chain jiggle damping must be a number", .{}),
                                    }
                                }
                            }
                        }
                    }
                }
                if (shape_ok) physics_body = body;
            }
            path.pop(physics_mark);
        }
        if (getField(object, "anchor")) |anchor_value| {
            const anchor_mark = path.push("anchor");
            if (try expectString(diags, path, anchor_value)) |anchor_name| {
                if (!std.mem.eql(u8, node_type, "model.gltf")) {
                    try diags.add(path.slice(), "anchor is a model.gltf field, found it on '{s}'", .{node_type});
                } else if (std.mem.eql(u8, anchor_name, "face")) {
                    face_anchor = true;
                } else if (std.mem.eql(u8, anchor_name, "body")) {
                    body_anchor = true;
                } else if (std.mem.eql(u8, anchor_name, "skeleton")) {
                    skeleton_anchor = true;
                } else if (std.mem.eql(u8, anchor_name, "world")) {
                    world_anchor = true;
                } else {
                    try diags.add(path.slice(), "unknown anchor '{s}'", .{anchor_name});
                }
            }
            path.pop(anchor_mark);
        }
        var retarget = false;
        if (getField(object, "retarget")) |rv| {
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "retarget is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (rv == .bool) {
                retarget = rv.bool;
            } else try diags.add(path.slice(), "retarget must be a boolean", .{});
        }
        var talk = false;
        if (getField(object, "talk")) |tv| {
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "talk is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (tv == .bool) {
                talk = tv.bool;
            } else try diags.add(path.slice(), "talk must be a boolean", .{});
        }
        if (getField(object, "control")) |cv| {
            const control_mark = path.push("control");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "control is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (cv != .object) {
                try diags.add(path.slice(), "control must be an object", .{});
            } else {
                var mc: ModelControl = .{};
                if (getField(cv.object, "orbit")) |b| {
                    if (b == .bool) mc.orbit = b.bool;
                }
                if (getField(cv.object, "dolly")) |b| {
                    if (b == .bool) mc.dolly = b.bool;
                }
                if (getField(cv.object, "roll")) |b| {
                    if (b == .bool) mc.roll = b.bool;
                }
                model_control = mc;
            }
            path.pop(control_mark);
        }
        if (getField(object, "graph")) |gv| {
            const graph_mark = path.push("graph");
            if (!std.mem.eql(u8, node_type, "logic.graph")) {
                try diags.add(path.slice(), "graph is a logic.graph field, found it on '{s}'", .{node_type});
            } else if (gv != .object) {
                try diags.add(path.slice(), "graph must be an object", .{});
            } else {
                logic_graph_spec = try parseLogicGraph(diags, path, arena, gv.object);
            }
            path.pop(graph_mark);
        }
        if (getField(object, "ml")) |mv| {
            const ml_mark = path.push("ml");
            if (!std.mem.eql(u8, node_type, "ml.infer")) {
                try diags.add(path.slice(), "ml is an ml.infer field, found it on '{s}'", .{node_type});
            } else if (mv != .object) {
                try diags.add(path.slice(), "ml must be an object", .{});
            } else {
                ml_field = try parseMlField(diags, path, arena, mv.object);
            }
            path.pop(ml_mark);
        }
        var diffusion_field: ?DiffusionField = null;
        if (getField(object, "diffusion")) |dv| {
            const diff_mark = path.push("diffusion");
            if (!std.mem.eql(u8, node_type, "diffusion")) {
                try diags.add(path.slice(), "diffusion is a diffusion-node field, found it on '{s}'", .{node_type});
            } else if (dv != .object) {
                try diags.add(path.slice(), "diffusion must be an object", .{});
            } else {
                diffusion_field = try parseDiffusionField(diags, path, arena, dv.object);
            }
            path.pop(diff_mark);
        }
        var splat_field: ?SplatField = null;
        if (getField(object, "splat")) |sv| {
            const splat_mark = path.push("splat");
            if (!std.mem.eql(u8, node_type, "splat.cloud")) {
                try diags.add(path.slice(), "splat is a splat.cloud field, found it on '{s}'", .{node_type});
            } else if (sv != .object) {
                try diags.add(path.slice(), "splat must be an object", .{});
            } else {
                splat_field = try parseSplatField(diags, path, arena, sv.object);
            }
            path.pop(splat_mark);
        }

        const clip_weights = try parseWeightNames(arena, diags, path, object, node_type, "clip_weights");
        const morph_weights = try parseWeightNames(arena, diags, path, object, node_type, "morph_weights");

        var mask_channel: ?u8 = null;
        if (getField(object, "mask")) |mask_value| {
            const mask_mark = path.push("mask");
            if (try expectString(diags, path, mask_value)) |mask_name| {
                if (!std.mem.eql(u8, node_type, "shader.pass")) {
                    try diags.add(path.slice(), "mask is a shader.pass field, found it on '{s}'", .{node_type});
                } else if (maskChannelIndex(mask_name)) |channel| {
                    mask_channel = channel;
                } else {
                    try diags.add(path.slice(), "unknown mask channel '{s}'", .{mask_name});
                }
            }
            path.pop(mask_mark);
        }

        var script_source: ?[]const u8 = null;
        if (std.mem.eql(u8, node_type, "script")) {
            const src_mark = path.push("source");
            if (getField(object, "source")) |src_value| {
                if (try expectString(diags, path, src_value)) |src| {
                    script_source = try arena.dupe(u8, src);
                }
            } else {
                try diags.add(path.slice(), "a script node needs a source", .{});
            }
            path.pop(src_mark);
        }

        try out.append(arena, .{
            .id = try arena.dupe(u8, id),
            .type = try arena.dupe(u8, node_type),
            .inputs = try inputs.toOwnedSlice(arena),
            .params = try params.toOwnedSlice(arena),
            .mask_channel = mask_channel,
            .face_anchor = face_anchor,
            .retarget = retarget,
            .talk = talk,
            .control = model_control,
            .logic_graph = logic_graph_spec,
            .ml = ml_field,
            .diffusion = diffusion_field,
            .splat = splat_field,
            .body_anchor = body_anchor,
            .skeleton_anchor = skeleton_anchor,
            .world_anchor = world_anchor,
            .physics = physics_body,
            .cloth = cloth_field,
            .balloon = balloon_field,
            .hair = hair_field,
            .particles = particle_field,
            .clip_weights = clip_weights,
            .morph_weights = morph_weights,
            .grade = grade_field,
            .dehaze = dehaze_field,
            .relight = relight_field,
            .glare = glare_field,
            .vignette = vignette_field,
            .lowlight = lowlight_field,
            .undistort = undistort_field,
            .material = material_field,
            .bloom = bloom_field,
            .dof = dof_field,
            .fog = fog_field,
            .outline = outline_field,
            .occluder = occluder_field,
            .cutout = cutout_field,
            .tint = tint_field,
            .smooth = smooth_field,
            .paint = paint_field,
            .swap = swap_field,
            .lashes = lash_field,
            .retouch = retouch_field,
            .matte = matte_field,
            .hair_matte = hair_matte_field,
            .stylize = stylize_field,
            .edge = edge_field,
            .warp = warp_field,
            .reshape = reshape_field,
            .trail = trail_field,
            .ssr = ssr_field,
            .env = env_field,
            .layout = layout_field,
            .sprite = sprite_field,
            .text = text_field,
            .video = video_field,
            .script = script_source,
        });
    }
    return try out.toOwnedSlice(arena);
}

fn parseLogicInput(object: std.json.ObjectMap, name: []const u8, ref_out: *[]const u8, lit_out: *f32, arena: std.mem.Allocator) error{OutOfMemory}!void {
    if (getField(object, name)) |v| {
        switch (v) {
            .string => |s| ref_out.* = try arena.dupe(u8, s),
            else => lit_out.* = @floatCast(numberOf(v) orelse 0),
        }
    }
}

fn parseLogicGraph(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?LogicGraphSpec {
    const output_param = if (getField(object, "output_param")) |v| (try expectString(diags, path, v) orelse "") else "";
    const output_id = if (getField(object, "output")) |v| (try expectString(diags, path, v) orelse "") else "";
    const nodes_val = getField(object, "nodes") orelse {
        try diags.add(path.slice(), "graph needs a nodes array", .{});
        return null;
    };
    if (nodes_val != .array) {
        try diags.add(path.slice(), "graph nodes must be an array", .{});
        return null;
    }
    var nodes: std.ArrayList(LogicNodeSpec) = .empty;
    for (nodes_val.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        var node: LogicNodeSpec = .{
            .id = try arena.dupe(u8, if (getField(o, "id")) |v| (try expectString(diags, path, v) orelse "") else ""),
            .op = try arena.dupe(u8, if (getField(o, "op")) |v| (try expectString(diags, path, v) orelse "") else ""),
        };
        try parseLogicInput(o, "a", &node.a_ref, &node.a_lit, arena);
        try parseLogicInput(o, "b", &node.b_ref, &node.b_lit, arena);
        try parseLogicInput(o, "c", &node.c_ref, &node.c_lit, arena);
        if (getField(o, "signal")) |v| {
            if (try expectString(diags, path, v)) |s| node.signal_source = try arena.dupe(u8, s);
        }
        if (getField(o, "param")) |v| {
            if (try expectString(diags, path, v)) |s| node.param_name = try arena.dupe(u8, s);
        }
        if (getField(o, "value")) |v| node.constant = @floatCast(numberOf(v) orelse 0);
        try nodes.append(arena, node);
    }
    return .{
        .nodes = try nodes.toOwnedSlice(arena),
        .output_id = try arena.dupe(u8, output_id),
        .output_param = try arena.dupe(u8, output_param),
    };
}

fn parseDiffusionField(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?DiffusionField {
    // The encoder is optional: with one the loop restyles the camera frame
    // (img2img), without one it generates from pure noise (text to image).
    const encoder = if (getField(object, "encoder")) |v| (try expectString(diags, path, v) orelse "") else "";
    const unet = if (getField(object, "unet")) |v| (try expectString(diags, path, v) orelse "") else "";
    const decoder = if (getField(object, "decoder")) |v| (try expectString(diags, path, v) orelse "") else "";
    const sprite = if (getField(object, "sprite")) |v| (try expectString(diags, path, v) orelse "") else "";
    if (unet.len == 0 or decoder.len == 0) {
        try diags.add(path.slice(), "diffusion needs unet and decoder model files", .{});
        return null;
    }
    if (sprite.len == 0) {
        try diags.add(path.slice(), "diffusion needs a sprite to draw the restyled frame through", .{});
        return null;
    }
    var field: DiffusionField = .{
        .encoder = try arena.dupe(u8, encoder),
        .unet = try arena.dupe(u8, unet),
        .decoder = try arena.dupe(u8, decoder),
        .sprite = try arena.dupe(u8, sprite),
    };
    if (getField(object, "text_embedding")) |v| {
        if (try expectString(diags, path, v)) |s| field.text_embedding = try arena.dupe(u8, s);
    }
    if (getField(object, "steps")) |v| {
        if (v == .integer and v.integer >= 1 and v.integer <= 16) field.steps = @intCast(v.integer);
    }
    if (getField(object, "strength")) |v| {
        field.strength = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.strength)), 0, 1);
    }
    if (getField(object, "seed")) |v| {
        if (v == .integer and v.integer >= 0) field.seed = @intCast(v.integer);
    }
    if (getField(object, "coherence")) |v| {
        field.coherence = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.coherence)), 0, 1);
    }
    return field;
}

fn parseSplatField(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?SplatField {
    const model = if (getField(object, "model")) |v| (try expectString(diags, path, v) orelse "") else "";
    if (model.len == 0) {
        try diags.add(path.slice(), "splat needs a model file", .{});
        return null;
    }
    var field: SplatField = .{ .model = try arena.dupe(u8, model) };
    if (getField(object, "source")) |v| {
        if (try expectString(diags, path, v)) |name| {
            if (std.mem.eql(u8, name, "camera")) field.source = .camera else if (std.mem.eql(u8, name, "selfie")) field.source = .selfie else try diags.add(path.slice(), "splat source is 'camera' or 'selfie', found '{s}'", .{name});
        }
    }
    if (getField(object, "draw")) |v| {
        if (try expectString(diags, path, v)) |name| {
            if (std.mem.eql(u8, name, "points")) field.draw = .points else if (std.mem.eql(u8, name, "mesh")) field.draw = .mesh else try diags.add(path.slice(), "splat draw is 'points' or 'mesh', found '{s}'", .{name});
        }
    }
    if (getField(object, "point")) |v| field.point = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.point)), 1, 64);
    if (getField(object, "r")) |v| field.r = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.r)), 0, 1);
    if (getField(object, "g")) |v| field.g = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.g)), 0, 1);
    if (getField(object, "b")) |v| field.b = std.math.clamp(@as(f32, @floatCast(numberOf(v) orelse field.b)), 0, 1);
    if (getField(object, "colored")) |v| {
        if (v == .bool) field.colored = v.bool;
    }
    return field;
}

fn parseMlField(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?MlField {
    const model = if (getField(object, "model")) |v| (try expectString(diags, path, v) orelse "") else "";
    if (model.len == 0) {
        try diags.add(path.slice(), "ml needs a model file", .{});
        return null;
    }
    var input_width: u32 = 0;
    var input_height: u32 = 0;
    if (getField(object, "input_width")) |v| {
        if (v == .integer and v.integer >= 0) input_width = @intCast(v.integer);
    }
    if (getField(object, "input_height")) |v| {
        if (v == .integer and v.integer >= 0) input_height = @intCast(v.integer);
    }
    var outputs: std.ArrayList(MlOutput) = .empty;
    if (getField(object, "outputs")) |ov| {
        if (ov == .array) {
            for (ov.array.items) |item| {
                if (item != .object) continue;
                const o = item.object;
                const param = if (getField(o, "param")) |v| (try expectString(diags, path, v) orelse "") else "";
                if (param.len == 0) continue;
                var out: MlOutput = .{ .param = try arena.dupe(u8, param) };
                if (getField(o, "tensor")) |v| {
                    if (v == .integer and v.integer >= 0) out.tensor = @intCast(v.integer);
                }
                if (getField(o, "index")) |v| {
                    if (v == .integer and v.integer >= 0) out.index = @intCast(v.integer);
                }
                if (getField(o, "reduce")) |v| {
                    if (try expectString(diags, path, v)) |name| {
                        out.reduce = std.meta.stringToEnum(MlReduce, name) orelse blk: {
                            try diags.add(path.slice(), "unknown ml output reduce '{s}'", .{name});
                            break :blk .element;
                        };
                    }
                }
                try outputs.append(arena, out);
            }
        }
    }
    var mask: ?MlMask = null;
    if (getField(object, "mask")) |mv| {
        const mask_mark = path.push("mask");
        if (mv != .object) {
            try diags.add(path.slice(), "ml mask must be an object", .{});
        } else {
            var m: MlMask = .{};
            if (getField(mv.object, "tensor")) |v| {
                if (v == .integer and v.integer >= 0) m.tensor = @intCast(v.integer);
            }
            const channel_name = if (getField(mv.object, "channel")) |v| (try expectString(diags, path, v) orelse "") else "";
            if (maskChannelIndex(channel_name)) |channel| {
                m.channel = channel;
                mask = m;
            } else {
                try diags.add(path.slice(), "ml mask needs a known channel, found '{s}'", .{channel_name});
            }
        }
        path.pop(mask_mark);
    }
    var style: ?MlStyle = null;
    if (getField(object, "style")) |sv| {
        const style_mark = path.push("style");
        if (sv != .object) {
            try diags.add(path.slice(), "ml style must be an object", .{});
        } else {
            const sprite_id = if (getField(sv.object, "sprite")) |v| (try expectString(diags, path, v) orelse "") else "";
            if (sprite_id.len == 0) {
                try diags.add(path.slice(), "ml style needs a sprite to draw through", .{});
            } else {
                var st: MlStyle = .{ .sprite = try arena.dupe(u8, sprite_id) };
                if (getField(sv.object, "tensor")) |v| {
                    if (v == .integer and v.integer >= 0) st.tensor = @intCast(v.integer);
                }
                style = st;
            }
        }
        path.pop(style_mark);
    }
    var aux_reference: []const u8 = "";
    var temporal = false;
    if (getField(object, "aux")) |av| {
        const aux_mark = path.push("aux");
        if (av != .object) {
            try diags.add(path.slice(), "ml aux must be an object", .{});
        } else {
            if (getField(av.object, "reference")) |v| {
                aux_reference = try expectString(diags, path, v) orelse "";
            }
            if (getField(av.object, "temporal")) |v| {
                temporal = v == .bool and v.bool;
            }
        }
        path.pop(aux_mark);
    }
    if (temporal and aux_reference.len > 0) {
        try diags.add(path.slice(), "ml aux cannot set both reference and temporal", .{});
        temporal = false;
    }
    return .{
        .model = try arena.dupe(u8, model),
        .input_width = input_width,
        .input_height = input_height,
        .outputs = try outputs.toOwnedSlice(arena),
        .mask = mask,
        .style = style,
        .aux_reference = try arena.dupe(u8, aux_reference),
        .temporal = temporal,
    };
}

fn parseAction(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?Action {
    const kind_mark = path.push("kind");
    const kind_str = try expectString(diags, path, getField(object, "kind")) orelse {
        path.pop(kind_mark);
        return null;
    };
    const kind = std.meta.stringToEnum(ActionKind, kind_str) orelse {
        try diags.add(path.slice(), "unknown action kind '{s}'", .{kind_str});
        path.pop(kind_mark);
        return null;
    };
    path.pop(kind_mark);

    var action = Action{ .kind = kind };
    if (getField(object, "target")) |v| {
        action.target = try arena.dupe(u8, switch (v) {
            .string => |s| s,
            else => blk: {
                const mark = path.push("target");
                try diags.add(path.slice(), "expected a string", .{});
                path.pop(mark);
                break :blk "";
            },
        });
    }
    if (getField(object, "to")) |v| {
        action.to = @floatCast(numberOf(v) orelse blk: {
            const mark = path.push("to");
            try diags.add(path.slice(), "expected a number", .{});
            path.pop(mark);
            break :blk 0;
        });
    }
    if (getField(object, "duration_ms")) |v| {
        const n = numberOf(v) orelse blk: {
            const mark = path.push("duration_ms");
            try diags.add(path.slice(), "expected a number", .{});
            path.pop(mark);
            break :blk 0;
        };
        // Bound the ms so the ramp's ms*1000 microsecond math stays inside u32;
        // an out-of-range duration is a diagnostic and holds at zero.
        if (!(n >= 0 and n <= max_duration_ms)) {
            const mark = path.push("duration_ms");
            try diags.add(path.slice(), "duration is out of range", .{});
            path.pop(mark);
            action.duration_ms = 0;
        } else {
            action.duration_ms = @intFromFloat(n);
        }
    }
    if (getField(object, "curve")) |v| {
        const s = switch (v) {
            .string => |str| str,
            else => "",
        };
        action.curve = std.meta.stringToEnum(Curve, s) orelse blk: {
            const mark = path.push("curve");
            try diags.add(path.slice(), "unknown curve '{s}'", .{s});
            path.pop(mark);
            break :blk .linear;
        };
    }
    if (getField(object, "stiffness")) |v| action.stiffness = @floatCast(numberOf(v) orelse 0);
    if (getField(object, "damping")) |v| action.damping = @floatCast(numberOf(v) orelse 0);
    return action;
}

fn parseTriggers(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Trigger {
    if (array.items.len > max_triggers) {
        try diags.add(path.slice(), "at most {d} triggers, found {d}", .{ max_triggers, array.items.len });
        return null;
    }
    var out: std.ArrayList(Trigger) = .empty;
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const when_mark = path.push("when");
        const when_source = try expectString(diags, path, getField(object, "when")) orelse {
            path.pop(when_mark);
            continue;
        };
        if (when_source.len > max_when_bytes) {
            try diags.add(path.slice(), "when exceeds {d} bytes", .{max_when_bytes});
            path.pop(when_mark);
            continue;
        }
        path.pop(when_mark);

        const action_mark = path.push("action");
        const action_object = try expectObject(diags, path, getField(object, "action")) orelse {
            path.pop(action_mark);
            continue;
        };
        const action = try parseAction(diags, path, arena, action_object) orelse {
            path.pop(action_mark);
            continue;
        };
        path.pop(action_mark);

        try out.append(arena, .{ .when_source = try arena.dupe(u8, when_source), .action = action });
    }
    return try out.toOwnedSlice(arena);
}

/// Parses and structurally validates one manifest.json: bundle-independent
/// limits, the top level schema, engine_compat, capability names, and
/// cross references between nodes/params/triggers.
/// Shader compilation and asset decode are the bundle loader's job, not
/// this function's - they need the rest of the bundle on disk. Returns
/// null with diags populated on any validation failure; never partially
/// returns a Manifest.
pub fn parse(gpa: std.mem.Allocator, diags: *Diagnostics, source: []const u8) error{OutOfMemory}!?Manifest {
    var path = PathStack{};
    if (source.len > max_manifest_bytes) {
        try diags.add("", "manifest exceeds {d} bytes (got {d})", .{ max_manifest_bytes, source.len });
        return null;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, source, .{}) catch |err| {
        try diags.add("", "invalid json: {t}", .{err});
        return null;
    };
    defer parsed.deinit();

    if (jsonDepth(parsed.value) > max_json_depth) {
        try diags.add("", "nesting exceeds a depth of {d}", .{max_json_depth});
        return null;
    }

    const root = try expectObject(diags, &path, parsed.value) orelse return null;

    var manifest: Manifest = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .glf_minor = 0,
        .id = "",
        .version = "",
        .display_name = "",
        .engine_compat = .{},
        .capabilities = &.{},
        .parameters = &.{},
        .nodes = &.{},
        .triggers = &.{},
    };
    errdefer manifest.arena.deinit();
    const arena = manifest.arena.allocator();

    const diags_before = diags.list.items.len;

    {
        const mark = path.push("glf");
        if (try expectString(diags, &path, getField(root, "glf"))) |glf| {
            const parsed_version = parseMajorMinor(glf);
            if (parsed_version == null or parsed_version.?.major != 1) {
                try diags.add(path.slice(), "unsupported glf version '{s}', this runtime is 1.x", .{glf});
            } else {
                manifest.glf_minor = parsed_version.?.minor;
            }
        }
        path.pop(mark);
    }
    {
        const mark = path.push("id");
        if (try expectString(diags, &path, getField(root, "id"))) |id| manifest.id = try arena.dupe(u8, id);
        path.pop(mark);
    }
    {
        const mark = path.push("version");
        if (try expectString(diags, &path, getField(root, "version"))) |v| manifest.version = try arena.dupe(u8, v);
        path.pop(mark);
    }
    {
        const mark = path.push("display_name");
        if (try expectString(diags, &path, getField(root, "display_name"))) |v| manifest.display_name = try arena.dupe(u8, v);
        path.pop(mark);
    }
    {
        const mark = path.push("engine_compat");
        if (try expectString(diags, &path, getField(root, "engine_compat"))) |s| {
            if (try parseEngineCompat(diags, &path, s)) |range| manifest.engine_compat = range;
        }
        path.pop(mark);
    }
    {
        const mark = path.push("capabilities");
        if (try expectArray(diags, &path, getField(root, "capabilities"))) |array| {
            manifest.capabilities = try parseCapabilities(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("parameters");
        if (try expectArray(diags, &path, getField(root, "parameters"))) |array| {
            manifest.parameters = try parseParameters(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("nodes");
        if (try expectArray(diags, &path, getField(root, "nodes"))) |array| {
            manifest.nodes = try parseNodes(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("triggers");
        if (try expectArray(diags, &path, getField(root, "triggers"))) |array| {
            manifest.triggers = try parseTriggers(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    if (getField(root, "volume")) |vv| {
        const mark = path.push("volume");
        if (vv != .object) {
            try diags.add(path.slice(), "volume must be an object", .{});
        } else {
            var vol: Volume = .{};
            if (getField(vv.object, "center")) |c| {
                if (!readVec3(c, &vol.center)) try diags.add(path.slice(), "volume center must be three numbers", .{});
            }
            if (getField(vv.object, "radius")) |r| {
                vol.radius = std.math.clamp(@as(f32, @floatCast(numberOf(r) orelse 0)), 0.0, 1000.0);
            }
            if (getField(vv.object, "half")) |h| {
                if (!readVec3(h, &vol.half)) try diags.add(path.slice(), "volume half must be three numbers", .{});
            }
            if (vol.radius <= 0 and vol.half[0] <= 0 and vol.half[1] <= 0 and vol.half[2] <= 0) {
                try diags.add(path.slice(), "volume needs a positive radius (sphere) or half extents (box)", .{});
            } else {
                manifest.volume = vol;
            }
        }
        path.pop(mark);
    }

    try crossReference(diags, &path, arena, &manifest);

    if (diags.list.items.len > diags_before) {
        manifest.arena.deinit();
        return null;
    }
    return manifest;
}

/// Node inputs/params referencing an id or parameter that does not exist,
/// and trigger actions referencing a node id or parameter that does not
/// exist - its own validation stage, run only after the per-array shapes
/// above are already known good.
fn crossReference(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, manifest: *const Manifest) error{OutOfMemory}!void {
    var node_ids = std.StringHashMap(void).init(arena);
    for (manifest.nodes) |node| try node_ids.put(node.id, {});
    var param_names = std.StringHashMap(void).init(arena);
    for (manifest.parameters) |p| try param_names.put(p.name, {});

    const nodes_mark = path.push("nodes");
    for (manifest.nodes, 0..) |node, i| {
        const node_mark = path.pushIndex(i);
        const inputs_mark = path.push("inputs");
        for (node.inputs) |input| {
            // "camera" is the implicit capture input every lens graph
            // starts from; every other source must be a node id declared
            // above.
            if (!std.mem.eql(u8, input.source, "camera") and !node_ids.contains(input.source)) {
                const field_mark = path.push(input.name);
                try diags.add(path.slice(), "input '{s}' names unknown node id '{s}'", .{ input.name, input.source });
                path.pop(field_mark);
            }
        }
        path.pop(inputs_mark);
        const params_mark = path.push("params");
        for (node.params) |param| {
            if (param.binding == .param_ref and !param_names.contains(param.binding.param_ref)) {
                const field_mark = path.push(param.name);
                try diags.add(path.slice(), "binds unknown parameter '{s}'", .{param.binding.param_ref});
                path.pop(field_mark);
            }
        }
        path.pop(params_mark);
        const cw_mark = path.push("clip_weights");
        for (node.clip_weights, 0..) |name, ci| {
            if (!param_names.contains(name)) {
                const idx_mark = path.pushIndex(ci);
                try diags.add(path.slice(), "clip weight binds unknown parameter '{s}'", .{name});
                path.pop(idx_mark);
            }
        }
        path.pop(cw_mark);
        const mw_mark = path.push("morph_weights");
        for (node.morph_weights, 0..) |name, mi| {
            if (!param_names.contains(name)) {
                const idx_mark = path.pushIndex(mi);
                try diags.add(path.slice(), "morph weight binds unknown parameter '{s}'", .{name});
                path.pop(idx_mark);
            }
        }
        path.pop(mw_mark);
        if (node.sprite) |sp| {
            if (sp.opacity_param.len > 0 and !param_names.contains(sp.opacity_param)) {
                try diags.add(path.slice(), "sprite opacity_param binds unknown parameter '{s}'", .{sp.opacity_param});
            }
        }
        if (node.text) |tf| {
            if (tf.opacity_param.len > 0 and !param_names.contains(tf.opacity_param)) {
                try diags.add(path.slice(), "text opacity_param binds unknown parameter '{s}'", .{tf.opacity_param});
            }
        }
        path.pop(node_mark);
    }
    path.pop(nodes_mark);

    const triggers_mark = path.push("triggers");
    for (manifest.triggers, 0..) |trigger, i| {
        const trigger_mark = path.pushIndex(i);
        const action_mark = path.push("action");
        const needs_param = switch (trigger.action.kind) {
            .param_ramp, .param_set => true,
            else => false,
        };
        const needs_node = switch (trigger.action.kind) {
            .show, .hide, .swap_subgraph, .play_animation => true,
            else => false,
        };
        if (needs_param and !param_names.contains(trigger.action.target)) {
            try diags.add(path.slice(), "targets unknown parameter '{s}'", .{trigger.action.target});
        }
        if (needs_node and !node_ids.contains(trigger.action.target)) {
            try diags.add(path.slice(), "targets unknown node id '{s}'", .{trigger.action.target});
        }
        path.pop(action_mark);
        path.pop(trigger_mark);
    }
    path.pop(triggers_mark);
}

const t = std.testing;

fn parseOk(source: []const u8) !Manifest {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    const result = try parse(t.allocator, &diags, source);
    if (result == null) {
        for (diags.list.items) |d| std.debug.print("{s}: {s}\n", .{ d.path, d.message });
    }
    return result orelse error.TestUnexpectedResult;
}

const FailedParse = struct {
    arena: std.heap.ArenaAllocator,
    diags: std.ArrayList(Diagnostic),

    fn deinit(self: *FailedParse) void {
        self.arena.deinit();
    }
};

fn parseFails(source: []const u8) !FailedParse {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    const result = try parse(t.allocator, &diags, source);
    if (result) |*m| {
        var mutable = m.*;
        mutable.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .arena = arena, .diags = diags.list };
}

const minimal_valid =
    \\{
    \\  "glf": "1.0",
    \\  "id": "com.example.mylens",
    \\  "version": "1.0.0",
    \\  "display_name": "My Lens",
    \\  "engine_compat": ">=0.5 <1.0",
    \\  "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.5, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('mouthOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

test "a minimal valid manifest parses with every field populated" {
    var manifest = try parseOk(minimal_valid);
    defer manifest.deinit();
    try t.expectEqualStrings("com.example.mylens", manifest.id);
    try t.expectEqual(@as(usize, 1), manifest.capabilities.len);
    try t.expectEqual(Capability.face, manifest.capabilities[0]);
    try t.expectEqual(@as(usize, 1), manifest.parameters.len);
    try t.expectEqualStrings("smooth_amount", manifest.parameters[0].name);
    try t.expectEqual(@as(f32, 0.5), manifest.parameters[0].default.float);
    try t.expectEqual(@as(usize, 1), manifest.nodes.len);
    try t.expectEqualStrings("camera", manifest.nodes[0].inputs[0].source);
    try t.expectEqualStrings("smooth_amount", manifest.nodes[0].params[0].binding.param_ref);
    try t.expectEqual(@as(usize, 1), manifest.triggers.len);
    try t.expectEqual(ActionKind.param_ramp, manifest.triggers[0].action.kind);
    try t.expect(manifest.engine_compat.contains(0, 5));
    try t.expect(!manifest.engine_compat.contains(1, 0));
    try t.expect(!manifest.engine_compat.contains(0, 4));
}

test "a material graph parses on a shader.pass node" {
    const src =
        \\{
        \\  "glf": "1.0", "id": "com.example.mat", "version": "1.0.0",
        \\  "display_name": "Mat", "engine_compat": ">=0.5 <1.0",
        \\  "capabilities": [], "parameters": [],
        \\  "nodes": [
        \\    {"id": "mat", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {},
        \\     "material": {"output": 3, "nodes": [
        \\        {"kind": "uv"},
        \\        {"kind": "texture", "name": "albedo"},
        \\        {"kind": "sample", "inputs": [1, 0]},
        \\        {"kind": "output", "inputs": [2]}
        \\     ]}}
        \\  ],
        \\  "triggers": []
        \\}
    ;
    var manifest = try parseOk(src);
    defer manifest.deinit();
    const g = manifest.nodes[0].material orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(usize, 4), g.nodes.len);
    try t.expectEqual(@as(u32, 3), g.root);
}

test "a material on a non shader.pass node is rejected" {
    const src =
        \\{
        \\  "glf": "1.0", "id": "com.example.mat", "version": "1.0.0",
        \\  "display_name": "Mat", "engine_compat": ">=0.5 <1.0",
        \\  "capabilities": [], "parameters": [],
        \\  "nodes": [
        \\    {"id": "b", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {},
        \\     "material": {"output": 0, "nodes": [{"kind": "output", "inputs": [0]}]}}
        \\  ],
        \\  "triggers": []
        \\}
    ;
    var failed = try parseFails(src);
    defer failed.deinit();
    var found = false;
    for (failed.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "material is a shader.pass field") != null) found = true;
    }
    try t.expect(found);
}

test "a missing required field reports its exact path" {
    const source =
        \\{"glf": "1.0", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    try t.expect(result.diags.items.len >= 1);
    try t.expectEqualStrings("/id", result.diags.items[0].path);
}

test "an unknown node type is not rejected here, unknown capability is" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["telepathy"], "parameters": [], "nodes": [], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.eql(u8, d.path, "/capabilities/0")) found = true;
    }
    try t.expect(found);
}

test "a node input naming an unknown node id fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "beauty.reshape", "inputs": {"frame": "nonexistent"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown node id") != null) found = true;
    }
    try t.expect(found);
}

test "a cloth field parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "flag", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "cloth": {"cols": 10, "rows": 6, "width": 1.5, "height": 1.0}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const cloth = manifest.nodes[0].cloth.?;
    try t.expectEqual(@as(u32, 10), cloth.cols);
    try t.expectEqual(@as(u32, 6), cloth.rows);
    try t.expectEqual(@as(f32, 1.5), cloth.width);
}

test "a script node captures its inline source" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "intensity", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}], "nodes": [
        \\   {"id": "drive", "type": "script", "params": {},
        \\    "source": "function update(lens) { lens.params.intensity = lens.signals.face_present > 0.5 ? 0.8 : 0.2; }"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expectEqual(@as(usize, 1), manifest.nodes.len);
    try t.expectEqualStrings("script", manifest.nodes[0].type);
    try t.expect(manifest.nodes[0].script != null);
}

test "a physics chain parses its target and length" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "anchor", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "box", "motion": "kinematic"}},
        \\   {"id": "bead", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "sphere", "motion": "dynamic", "chain": {"to": "anchor", "length": 0.4}}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].physics.?.kinematic);
    const bead = manifest.nodes[1].physics.?;
    try t.expectEqualStrings("anchor", bead.chain_to.?);
    try t.expectEqual(@as(f32, 0.4), bead.chain_length);
}

test "a physics body parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "sphere", "size": [0.2, 0, 0], "position": [0, 1.5, 0], "motion": "dynamic"}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const body = manifest.nodes[0].physics.?;
    try t.expect(body.shape == .sphere);
    try t.expectEqual(@as(f32, 0.2), body.size[0]);
    try t.expectEqual(@as(f32, 1.5), body.position[1]);
    try t.expect(body.dynamic);
}

test "a physics chain jiggle count past a sane cap is clamped, not a crash" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "anchor", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "box", "motion": "kinematic"}},
        \\   {"id": "bead", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "sphere", "motion": "dynamic",
        \\     "chain": {"to": "anchor", "length": 0.4, "jiggle": {"segments": 4294967296}}}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[1].physics.?.jiggle_segments <= 128);
}

test "physics on a non-model node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}, "physics": {"body": "box"}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "physics is a model.gltf field") != null) found = true;
    }
    try t.expect(found);
}

test "a face anchor parses on a model node and only there" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["face"], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "face"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].face_anchor);
}

test "a body anchor parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["face"], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "body"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].body_anchor);
    try t.expect(!manifest.nodes[0].face_anchor);
}

test "a skeleton anchor parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["face"], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "skeleton"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].skeleton_anchor);
    try t.expect(!manifest.nodes[0].body_anchor);
}

test "an anchor on a non-model node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {}, "anchor": "face"}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "anchor is a model.gltf field") != null) found = true;
    }
    try t.expect(found);
}

test "an unknown anchor name is rejected" {
    const source =
        \\{"glf": "1.0", "id": "m", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "elbow"}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown anchor") != null) found = true;
    }
    try t.expect(found);
}

test "clip weights parse on a model node and bind declared parameters" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "walk", "type": "float", "default": 1.0, "min": 0.0, "max": 1.0},
        \\   {"name": "run", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "clip_weights": ["walk", "run"]}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expectEqual(@as(usize, 2), manifest.nodes[0].clip_weights.len);
    try t.expectEqualStrings("walk", manifest.nodes[0].clip_weights[0]);
    try t.expectEqualStrings("run", manifest.nodes[0].clip_weights[1]);
}

test "a clip weight binding an unknown parameter fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "walk", "type": "float", "default": 1.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "clip_weights": ["walk", "sprint"]}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "clip weight binds unknown parameter 'sprint'") != null) found = true;
    }
    try t.expect(found);
}

test "clip weights on a non-model node are rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "walk", "type": "float", "default": 1.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "a", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {}, "clip_weights": ["walk"]}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "clip_weights is a model.gltf field") != null) found = true;
    }
    try t.expect(found);
}

test "morph weights parse on a model node and bind declared parameters" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "smile", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0},
        \\   {"name": "blink", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "morph_weights": ["smile", "blink"]}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expectEqual(@as(usize, 2), manifest.nodes[0].morph_weights.len);
    try t.expectEqualStrings("smile", manifest.nodes[0].morph_weights[0]);
    try t.expectEqualStrings("blink", manifest.nodes[0].morph_weights[1]);
}

test "a morph weight binding an unknown parameter fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "smile", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "morph_weights": ["smile", "frown"]}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "morph weight binds unknown parameter 'frown'") != null) found = true;
    }
    try t.expect(found);
}

test "a sprite.2d node parses its rect and opacity" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}, "sprite": {"x": 0.25, "y": 0.1, "w": 0.5, "h": 0.3, "opacity": 0.8}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const sp = manifest.nodes[0].sprite orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 0.25), sp.x, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.5), sp.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 0.8), sp.opacity, 0.001);
}

test "a sprite.2d node parses its placement parameters" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "marker", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {},
        \\    "sprite": {"x": 0.0, "y": 0.0, "w": 0.2, "h": 0.2, "x_param": "box_x", "y_param": "box_y"}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const sp = manifest.nodes[0].sprite orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("box_x", sp.x_param);
    try t.expectEqualStrings("box_y", sp.y_param);
    try t.expectEqualStrings("", sp.w_param);
}

test "a sprite.2d node parses its interaction block" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {},
        \\    "sprite": {"x": 0.4, "y": 0.4, "w": 0.2, "h": 0.2, "interaction": {"drag": true, "pinch": true, "rotate": true, "tap_event": "hit"}}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const sp = manifest.nodes[0].sprite orelse return error.TestUnexpectedResult;
    try t.expect(sp.interaction.drag);
    try t.expect(sp.interaction.pinch);
    try t.expect(sp.interaction.rotate);
    try t.expectEqualStrings("hit", sp.interaction.tap_event);
    try t.expect(sp.interaction.any());
}

test "a model.gltf node parses its turntable control block" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "figure", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "control": {"orbit": true, "dolly": true, "roll": true}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const control = manifest.nodes[0].control orelse return error.TestUnexpectedResult;
    try t.expect(control.orbit);
    try t.expect(control.dolly);
    try t.expect(control.roll);
    try t.expect(control.any());
}

test "an ml.infer node parses its model slot and output bindings" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "classifier", "type": "ml.infer", "params": {},
        \\    "ml": {"model": "model.tflite", "input_width": 224, "input_height": 224,
        \\      "outputs": [{"tensor": 0, "index": 5, "param": "cat_score"}]}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const ml = manifest.nodes[0].ml orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("model.tflite", ml.model);
    try t.expectEqual(@as(u32, 224), ml.input_width);
    try t.expectEqual(@as(usize, 1), ml.outputs.len);
    try t.expectEqual(@as(u32, 5), ml.outputs[0].index);
    try t.expectEqualStrings("cat_score", ml.outputs[0].param);
}

test "an ml.infer output parses an argmax reduce" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "cls", "type": "ml.infer", "params": {},
        \\    "ml": {"model": "cls.onnx",
        \\      "outputs": [{"tensor": 0, "reduce": "argmax", "param": "label"},
        \\                  {"tensor": 0, "index": 2, "param": "score"}]}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const ml = manifest.nodes[0].ml orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(usize, 2), ml.outputs.len);
    try t.expectEqual(MlReduce.argmax, ml.outputs[0].reduce);
    try t.expectEqual(MlReduce.element, ml.outputs[1].reduce);
}

test "an ml.infer node parses a mask binding to a named channel" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "seg", "type": "ml.infer", "params": {},
        \\    "ml": {"model": "seg.onnx", "outputs": [],
        \\      "mask": {"tensor": 0, "channel": "hair"}}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const ml = manifest.nodes[0].ml orelse return error.TestUnexpectedResult;
    const mask = ml.mask orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 0), mask.tensor);
    try t.expectEqual(@as(u8, 2), mask.channel);
}

test "a diffusion node parses its three models and sampler settings" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "restyle", "type": "diffusion", "params": {},
        \\    "diffusion": {"encoder": "vae_enc.onnx", "unet": "unet.onnx", "decoder": "vae_dec.onnx",
        \\      "sprite": "canvas", "steps": 6, "strength": 0.4, "seed": 7}},
        \\   {"id": "canvas", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const d = manifest.nodes[0].diffusion orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("unet.onnx", d.unet);
    try t.expectEqualStrings("canvas", d.sprite);
    try t.expectEqual(@as(u32, 6), d.steps);
    try t.expectApproxEqAbs(@as(f32, 0.4), d.strength, 0.001);
    try t.expectEqual(@as(u64, 7), d.seed);
}

test "a diffusion node missing a model is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "restyle", "type": "diffusion", "params": {},
        \\    "diffusion": {"encoder": "vae_enc.onnx", "decoder": "vae_dec.onnx", "sprite": "canvas"}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "diffusion needs unet and decoder") != null) found = true;
    }
    try t.expect(found);
}

test "an ml.infer node parses a style binding to a sprite" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "restyle", "type": "ml.infer", "params": {},
        \\    "ml": {"model": "style.onnx", "outputs": [],
        \\      "style": {"tensor": 0, "sprite": "canvas"}}},
        \\   {"id": "canvas", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const ml = manifest.nodes[0].ml orelse return error.TestUnexpectedResult;
    const style = ml.style orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 0), style.tensor);
    try t.expectEqualStrings("canvas", style.sprite);
}

test "an ml.infer mask with an unknown channel is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "seg", "type": "ml.infer", "params": {},
        \\    "ml": {"model": "seg.onnx", "outputs": [],
        \\      "mask": {"tensor": 0, "channel": "not_a_channel"}}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "ml mask needs a known channel") != null) found = true;
    }
    try t.expect(found);
}

test "a sprite.2d node with no sprite block defaults to full frame" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const sp = manifest.nodes[0].sprite orelse return error.TestUnexpectedResult;
    try t.expectApproxEqAbs(@as(f32, 1.0), sp.w, 0.001);
    try t.expectApproxEqAbs(@as(f32, 1.0), sp.opacity, 0.001);
}

test "a sprite block on a non-sprite node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}, "sprite": {"x": 0.1}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "sprite is a sprite.2d field") != null) found = true;
    }
    try t.expect(found);
}

test "a sprite opacity_param binding an unknown parameter fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}, "sprite": {"x": 0.3, "opacity_param": "pulse"}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "sprite opacity_param binds unknown parameter 'pulse'") != null) found = true;
    }
    try t.expect(found);
}

test "a sprite opacity_param naming a declared parameter parses" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
        \\   {"name": "pulse", "type": "float", "default": 1.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [
        \\   {"id": "badge", "type": "sprite.2d", "inputs": {"frame": "camera"}, "params": {}, "sprite": {"x": 0.3, "opacity_param": "pulse"}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expectEqualStrings("pulse", manifest.nodes[0].sprite.?.opacity_param);
}

test "a text.2d node parses its content, rect, and color" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "label", "type": "text.2d", "inputs": {"frame": "camera"}, "params": {}, "text": {"content": "HELLO", "x": 0.1, "y": 0.8, "w": 0.8, "h": 0.15, "color": [1.0, 0.0, 0.0]}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const tf = manifest.nodes[0].text orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("HELLO", tf.content);
    try t.expectApproxEqAbs(@as(f32, 0.8), tf.w, 0.001);
    try t.expectEqual(@as(u8, 255), tf.r);
    try t.expectEqual(@as(u8, 0), tf.g);
}

test "a text.2d node with no text block is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "label", "type": "text.2d", "inputs": {"frame": "camera"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "a text.2d node needs a text block") != null) found = true;
    }
    try t.expect(found);
}

test "a text block on a non-text node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}, "text": {"content": "HI"}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "text is a text.2d field") != null) found = true;
    }
    try t.expect(found);
}

test "a trigger action targeting an unknown parameter fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [], "triggers": [
        \\   {"when": "tap", "action": {"kind": "param_set", "target": "nope", "to": 1.0}}
        \\ ]}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown parameter") != null) found = true;
    }
    try t.expect(found);
}

test "too many parameters is rejected before any of them are parsed" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendSlice(t.allocator,
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
    );
    for (0..max_parameters + 1) |i| {
        if (i != 0) try buf.appendSlice(t.allocator, ",");
        const entry = try std.fmt.allocPrint(
            t.allocator,
            "{{\"name\": \"p{d}\", \"type\": \"float\", \"default\": 0, \"min\": 0, \"max\": 1}}",
            .{i},
        );
        defer t.allocator.free(entry);
        try buf.appendSlice(t.allocator, entry);
    }
    try buf.appendSlice(t.allocator, "], \"nodes\": [], \"triggers\": []}");
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expectEqualStrings("/parameters", result.diags.items[0].path);
}

test "nesting past the depth limit is rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    for (0..max_json_depth + 4) |_| try buf.appendSlice(t.allocator, "[");
    try buf.appendSlice(t.allocator, "0");
    for (0..max_json_depth + 4) |_| try buf.appendSlice(t.allocator, "]");
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expect(std.mem.indexOf(u8, result.diags.items[0].message, "depth") != null);
}

test "a manifest over the byte limit is rejected before json parsing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendNTimes(t.allocator, ' ', max_manifest_bytes + 1);
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expect(std.mem.indexOf(u8, result.diags.items[0].message, "exceeds") != null);
}

test "engine_compat range boundaries are exact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    var path = PathStack{};
    const range = (try parseEngineCompat(&diags, &path, ">=0.5 <1.0")).?;
    try t.expect(range.contains(0, 5));
    try t.expect(range.contains(0, 9));
    try t.expect(!range.contains(0, 4));
    try t.expect(!range.contains(1, 0));
}

test "scene classes append at the frozen mask-channel tail" {
    // The tail indices the scene slot and its proof pin. Existing channels keep
    // their numbers; the scene classes only extend the vocabulary.
    try t.expectEqual(@as(?u8, 21), maskChannelIndex("hair_matte"));
    try t.expectEqual(@as(?u8, 22), maskChannelIndex("sky"));
    try t.expectEqual(@as(?u8, 23), maskChannelIndex("ground"));
    try t.expectEqual(@as(?u8, 24), maskChannelIndex("building"));
    try t.expectEqual(sky_channel, maskChannelIndex("sky").?);
    try t.expectEqual(ground_channel, maskChannelIndex("ground").?);
    try t.expectEqual(building_channel, maskChannelIndex("building").?);
    try t.expectEqual(@as(usize, 25), mask_channels.len);
}

/// The on-device prompt-to-lens compiler: it turns a short text prompt into a
/// GLF manifest composing the engine's asset-free post-effect nodes, so a lens
/// is authored from words with no upload and no round trip. The output is plain
/// GLF a caller can inspect, save, or hand straight to activate.
pub const prompt = struct {
    /// A colour-grade look. At most one grades the frame, so competing words
    /// resolve to the first the prompt names.
    const Grade = enum { none, warm, cool, bright, moody, mono };

    /// The recognized looks, filled by scanning the prompt's words. Each effect
    /// is a single asset-free node, so the emitted bundle needs no assets.
    const Recipe = struct {
        grade: Grade = .none,
        bloom: bool = false,
        blur: bool = false,
        fog: bool = false,
        edge: bool = false,
        stylize: bool = false,

        fn empty(self: Recipe) bool {
            return self.grade == .none and !self.bloom and !self.blur and !self.fog and !self.edge and !self.stylize;
        }
    };

    fn isWordChar(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
    }

    fn eqIgnoreCase(word: []const u8, lower: []const u8) bool {
        if (word.len != lower.len) return false;
        for (word, lower) |w, l| {
            const wl = if (w >= 'A' and w <= 'Z') w + 32 else w;
            if (wl != l) return false;
        }
        return true;
    }

    /// Folds one prompt word into the recipe. The grade slot keeps the first
    /// look a word claims; the post effects each latch on independently.
    fn applyWord(recipe: *Recipe, word: []const u8) void {
        const warm = [_][]const u8{ "warm", "vintage", "sepia", "sunset", "golden", "cozy" };
        const cool = [_][]const u8{ "cool", "cold", "icy", "winter", "blue" };
        const bright = [_][]const u8{ "bright", "vivid", "pop", "vibrant", "punchy" };
        const moody = [_][]const u8{ "moody", "dark", "dramatic", "cinematic", "noir" };
        const mono = [_][]const u8{ "mono", "bw", "grayscale", "greyscale", "monochrome" };
        const bloom = [_][]const u8{ "glow", "bloom", "dreamy", "soft", "ethereal" };
        const blur = [_][]const u8{ "blur", "hazy", "haze", "smooth" };
        const fog = [_][]const u8{ "fog", "foggy", "mist", "misty" };
        const edge = [_][]const u8{ "cartoon", "toon", "comic", "ink", "outline" };
        const stylize = [_][]const u8{ "sketch", "hatch", "pencil", "crosshatch", "drawn" };

        if (recipe.grade == .none) {
            for (warm) |w| if (eqIgnoreCase(word, w)) {
                recipe.grade = .warm;
                return;
            };
            for (cool) |w| if (eqIgnoreCase(word, w)) {
                recipe.grade = .cool;
                return;
            };
            for (bright) |w| if (eqIgnoreCase(word, w)) {
                recipe.grade = .bright;
                return;
            };
            for (moody) |w| if (eqIgnoreCase(word, w)) {
                recipe.grade = .moody;
                return;
            };
            for (mono) |w| if (eqIgnoreCase(word, w)) {
                recipe.grade = .mono;
                return;
            };
        }
        for (bloom) |w| {
            if (eqIgnoreCase(word, w)) recipe.bloom = true;
        }
        for (blur) |w| {
            if (eqIgnoreCase(word, w)) recipe.blur = true;
        }
        for (fog) |w| {
            if (eqIgnoreCase(word, w)) recipe.fog = true;
        }
        for (edge) |w| {
            if (eqIgnoreCase(word, w)) recipe.edge = true;
        }
        for (stylize) |w| {
            if (eqIgnoreCase(word, w)) recipe.stylize = true;
        }
    }

    fn scan(text: []const u8) Recipe {
        var recipe: Recipe = .{};
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !isWordChar(text[i])) i += 1;
            const start = i;
            while (i < text.len and isWordChar(text[i])) i += 1;
            if (i > start) applyWord(&recipe, text[start..i]);
        }
        return recipe;
    }

    fn gradeBlock(grade: Grade) []const u8 {
        return switch (grade) {
            .warm => "\"grade\": {\"exposure\": 0.1, \"contrast\": 1.1, \"saturation\": 1.2, \"temperature\": 0.06}",
            .cool => "\"grade\": {\"exposure\": 0.0, \"contrast\": 1.1, \"saturation\": 1.1, \"temperature\": -0.06}",
            .bright => "\"grade\": {\"exposure\": 0.2, \"contrast\": 1.15, \"saturation\": 1.3, \"temperature\": 0.0}",
            .moody => "\"grade\": {\"exposure\": -0.15, \"contrast\": 1.4, \"saturation\": 0.9, \"temperature\": -0.02}",
            .mono => "\"grade\": {\"exposure\": 0.0, \"contrast\": 1.2, \"saturation\": 0.0, \"temperature\": 0.0}",
            .none => "\"grade\": {\"exposure\": 0.05, \"contrast\": 1.05, \"saturation\": 1.1, \"temperature\": 0.0}",
        };
    }

    fn emitNode(w: *std.Io.Writer, first: *bool, id: []const u8, node_type: []const u8, block: ?[]const u8) !void {
        if (!first.*) try w.writeAll(",\n  ");
        first.* = false;
        try w.print("{{\"id\": \"{s}\", \"type\": \"{s}\", \"inputs\": {{\"frame\": \"camera\"}}, \"params\": {{}}", .{ id, node_type });
        if (block) |b| try w.print(", {s}", .{b});
        try w.writeAll("}");
    }

    /// Compiles `text` into a GLF manifest string. The nodes emit in a fixed
    /// effect order regardless of word order, so the same prompt always yields
    /// the same bundle. A prompt that names no look still grades gently, so the
    /// compiler never emits an empty lens. The caller owns the returned bytes.
    pub fn compile(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        var recipe = scan(text);
        if (recipe.empty()) recipe.grade = .none; // the gentle default look

        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        const w = &out.writer;
        try w.writeAll(
            \\{"glf": "1.0", "id": "goss.prompt.compiled", "version": "1.0.0", "display_name": "Prompt Lens", "engine_compat": ">=0.5", "capabilities": [], "parameters": [],
            \\ "nodes": [
        );
        var first = true;
        // Grade always emits (the default look when the prompt named none), then
        // the post effects follow in a stable chain order.
        try emitNode(w, &first, "grade", "grade.pass", gradeBlock(recipe.grade));
        if (recipe.blur) try emitNode(w, &first, "blur", "blur.pass", null);
        if (recipe.bloom) try emitNode(w, &first, "bloom", "bloom.pass", "\"bloom\": {\"threshold\": 0.6, \"intensity\": 0.8}");
        if (recipe.fog) try emitNode(w, &first, "fog", "fog.pass", "\"fog\": {\"color\": [0.8, 0.85, 0.9], \"density\": 1.2}");
        if (recipe.edge) try emitNode(w, &first, "edge", "edge.pass", "\"edge\": {\"mode\": \"canny\", \"low_threshold\": 0.1, \"high_threshold\": 0.5, \"blur_radius\": 4.0}");
        if (recipe.stylize) try emitNode(w, &first, "stylize", "stylize.pass", "\"stylize\": {\"mode\": \"crosshatch\", \"strength\": 1.0}");
        try w.writeAll("], \"triggers\": []}");
        return out.toOwnedSlice();
    }
};

test "prompt compiles to the looks it names" {
    const gpa = std.testing.allocator;
    const json = try prompt.compile(gpa, "warm dreamy cartoon");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"grade.pass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"temperature\": 0.06") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bloom.pass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edge.pass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blur.pass\"") == null);
}

test "prompt word order does not change the bundle" {
    const gpa = std.testing.allocator;
    const a = try prompt.compile(gpa, "cool blur glow");
    defer gpa.free(a);
    const b = try prompt.compile(gpa, "glow cool blur");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "prompt first grade word wins" {
    const gpa = std.testing.allocator;
    const json = try prompt.compile(gpa, "warm cool");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"temperature\": 0.06") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"temperature\": -0.06") == null);
}

test "prompt unrecognized still grades gently" {
    const gpa = std.testing.allocator;
    const json = try prompt.compile(gpa, "zzz qqq");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"grade.pass\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bloom.pass\"") == null);
}

test "prompt output parses as a valid lens" {
    const gpa = std.testing.allocator;
    const json = try prompt.compile(gpa, "cinematic glow foggy sketch");
    defer gpa.free(json);
    var parsed = try parseOk(json);
    defer parsed.deinit();
    try std.testing.expect(parsed.nodes.len >= 2);
}
