# The goss lens format (GLF)

GLF is the bundle format for a lens: a declarative package of parameters,
triggers, shaders, and assets that the engine's lens runtime splices
into a session's frame graph. This document is the format's spec, versioned
independently of the engine itself. The engine's lens runtime is one
conforming implementation; the validator (`lenses/validator`) is the reference
implementation of validation. Anything a conforming runtime does with a
`.glens` bundle, this document defines. If the runtime's behavior and this
document disagree, this document is right and the runtime has a bug.

Format version: GLF 1.0. Versions are `major.minor`. A runtime built against
major version N refuses any bundle declaring a different major version. A
minor version bump is additive only: new optional fields, new trigger
actions, new capability names. A runtime built against minor version M
accepts a bundle declaring any minor version ≤ M, and tolerates unknown
fields in a bundle declaring minor version > M (accept-and-ignore, not
reject) so old runtimes keep working against slightly newer content within
the same major version.

## 1. Bundle layout

A `.glens` bundle is a directory (or a zip archive of the same layout; the
runtime treats both identically, reading through a virtual file interface):

```
mylens.glens/
  manifest.json          required, described below
  shaders/                *.glsl source, plus *.<profile>.bin next to each
                          one once packaged (section 7) - metal/spirv/essl
  assets/                 *.gltf, *.glb, *.png, *.gif clips, LUTs, by relative path
  sounds/                 *.wav, *.mp3, *.flac, *.ogg, played by a play_sound trigger
```

No other file types are permitted inside a bundle. No file may reference a
path outside the bundle root (no `..` segments, no absolute paths, no
symlinks followed outside the root). The loader rejects any reference that
would escape, closed, before opening the file.

### 1.1 Size and depth limits

These bound the cost of loading and validating untrusted content; they are
part of the format, not an implementation detail:

- Bundle: 64 MiB total, uncompressed, all files combined.
- `manifest.json`: 256 KiB, parsed with a JSON depth limit of 32 (a
  manifest cannot recursively describe an unbounded trigger or parameter
  tree).
- Any single shader source file: 256 KiB.
- Any single asset file: 32 MiB.
- Parameters: 256 per lens. Triggers: 256 per lens. Nodes in the subgraph:
  128. Each of these is a flat count, not a nesting depth. The graph and
  trigger list are arrays, not trees, so there is no recursive case to
  bound separately.

A bundle exceeding any limit fails validation closed with a diagnostic
naming the limit and the measured value. The runtime never partially loads
an over-limit bundle.

## 2. manifest.json

Top level, all fields required unless marked optional:

```jsonc
{
  "glf": "1.0",                    // format version this manifest targets
  "id": "com.example.mylens",      // reverse-DNS style, stable identity
  "version": "1.2.0",              // semver, the lens's own version
  "display_name": "My Lens",
  "engine_compat": ">=0.5 <1.0",   // range against the engine's goss_abi_version
  "capabilities": ["face"],        // see 3
  "parameters": [ /* see 4 */ ],
  "nodes": [ /* see 5 */ ],
  "triggers": [ /* see 6 */ ]
}
```

`engine_compat` is a range expression over the ABI's `major.minor`
(`goss_abi_version`), checked at load time against the running engine; a
bundle whose range excludes the running engine fails validation closed
before any node, shader, or asset is touched.

## 3. Capabilities

A lens declares the inputs it needs so the runtime can decide, before
splicing, whether it can run: `face` (landmarks + blendshapes), `hands`
(hand landmarks, handedness, and canned gesture classes), `segmentation`
(selfie or hair mask), `world` (pose, planes, anchors, light),
`audio_level` (input signal envelope, for audio-reactive triggers). A
capability the
running session cannot provide is a defined degradation, not a load
failure: the lens still splices, its triggers gated on that capability
simply never fire, and any node consuming that capability's data holds its
last-known or default state. A named mask channel without live data
(the capability absent, the running model lacking that class, or the
first result not yet produced) samples the zero mask - the masked effect
draws nothing, never everywhere. A lens whose *every* node depends on an
unavailable capability degrades to not rendering, which the host app is
told about (so it can hide the lens from its picker) rather than the
runtime silently producing a blank frame with no explanation.

## 4. Parameters

A parameter is a named, typed, bounded value the host app or a trigger can
drive:

```jsonc
{
  "name": "smooth_amount",
  "type": "float",           // float | bool | int | color
  "default": 0.5,
  "min": 0.0, "max": 1.0     // required for float and int, ignored otherwise
}
```

A parameter changes at runtime three ways: a trigger ramp or set, a host
app write, or a script node (section 5). A parameter's value flows into node
inputs and shader uniforms by name binding declared in the node's `params`
map (section 5). Out-of-range values from any of them are clamped, never
rejected at runtime (rejection is a load-time validation concern; a running
lens never errors on a parameter write, it clamps and continues).

## 5. Node subgraph

The `nodes` array is a flat list of graph node instances the runtime
splices into the session graph as one fragment, wired by `inputs` naming
other nodes in the same list by their `id`:

```jsonc
{
  "id": "reshape",
  "type": "beauty.reshape",      // one of the runtime's known node types
  "inputs": { "frame": "camera" },  // "camera" is the implicit capture input
  "params": { "thin_face": "$smooth_amount" }  // "$name" binds a parameter
}
```

The beauty node types run the engine's built-in landmark retouch and makeup.
A `beauty.face` node softens skin with a `smooth` param (0..1) and brightens
teeth with a `whiten` param (0..1). A `beauty.reshape` node reshapes the face
by landmark: `thin_face` (0..1) narrows the jaw, `big_eye` (0..1) enlarges the
eyes. A `beauty.lipstick` node tints the lips and a `beauty.blusher` node
warms the cheeks, each driven by a single `blend` param (0..1) that fades the
effect in. All four read the tracked face landmarks, so they declare the
`face` capability and pass the frame through untouched without a tracked face,
the standard capability degradation. They carry no mask field: the makeup
region comes from the landmarks, not a named channel, which is what separates
them from the mask-keyed `tint.pass` and `smooth.pass` passes below.

A `model.gltf` node may add `"anchor": "face"`, pinning the model to the
tracked head: the runtime fits the canonical face's metric geometry to
the live landmarks and poses the model with that transform, so model
space is the canonical face's centimeter space (origin between the eyes,
x toward the subject's left, y up, z out of the face). Without a tracked
face the node draws nothing, the standard capability degradation.
`"anchor": "body"` pins the model to every tracked body: the runtime places
one instance at each submitted body's torso, scaled by torso length and
rolled by its tilt, so a body-anchored model fans out across a crowd (or
rides the single tracked figure when the host submits none). Without a
tracked body the node draws nothing. A body-anchored model that ships a glTF
skin poses instead of placing: each joint moves to its tracked landmark and
each limb bone rotates in the image plane toward the tracked joint below it,
so a rigged avatar mocaps the tracked body (a monocular, in-plane pose; the
single tracked figure drives it).
`"anchor": "skeleton"` draws the model once per bone of every tracked body,
each instance spanning the two joints of the bone (scaled to its length and
oriented along it), so the model tiles into a whole rig over the figure.
`"anchor": "world"` pins the model to the tracked world instead: model
space is world meters at the first submitted world anchor (or the world
origin without one), drawn from the platform camera's own pose and
projection; while tracking is anything but full, the node draws
nothing. `anchor` is rejected on every other node type, and `"face"`,
`"body"`, `"skeleton"`, and `"world"` are the only anchors GLF 1.0 defines.

A `model.gltf` node may add `"clip_weights"`: an array of parameter names,
one per animation clip in the order the glTF declares them. Each frame the
runtime samples every clip at the node's playback time and blends their
poses by those parameters' live values, a weighted mean of translation and
scale and a weighted nlerp of rotation, so a lens crossfades between
animations by moving the weights. Ramp them with `param_ramp` (6.3) for an
eased transition. Each name must be a declared parameter, a clip past the
list weighs nothing, and with no `clip_weights` the node plays its first
clip unchanged.

A `model.gltf` node may add `"morph_weights"`: an array of parameter names,
one per morph target (blendshape) in the order the glTF declares them. Each
frame the runtime deforms the mesh by the weighted sum of those targets'
per-vertex deltas, the weights taken from the named parameters' live values,
so ramping a weight opens a blendshape (a smile, a blink). Each name must be
a declared parameter, a target past the list contributes nothing, and with
no `morph_weights` the mesh draws unmorphed.

A face-anchored `model.gltf` node may add `"retarget": true` to turn the mesh
into an avatar of the user's face: each morph target whose glTF name matches an
ARKit blendshape (`jawOpen`, `eyeBlinkLeft`, and the rest) is driven each frame
by that live blendshape, and the head pose already rides the tracked face. A
target with no matching name still reads its `morph_weights` parameter, so a rig
can mix retargeted expression with authored morphs. With no tracked face the
mesh holds its rest shape. `retarget` is a `model.gltf` field only.

The driving performance need not be the local live face. A host that injects
faces through `goss_session_submit_faces` (blendshapes read off a source clip or
another camera) drives a retarget avatar from that performance instead, so one
selfie's avatar is reenacted by a separate source head.

A `model.gltf` node may add `"talk": true` to drive its `jawOpen` morph target
from the submitted audio, so the mesh mouths speech even with no tracked face: a
gated envelope of the voiced (low) audio band opens the jaw on vowels and closes
it on silence, overriding that one target's tracked or bound value. Combine
`retarget` and `talk` to lip-sync a tracked face's avatar to its own voice.
`talk` is a `model.gltf` field only.

A tracked avatar renders in any of the engine's art styles by drawing it and
adding a stylize node after it: a `stylize.pass` in `toon`, `sketch`, `emboss`
or `crosshatch` mode restyles the avatar, and a diffusion restyle masked to the
face channel repaints it, both while the avatar keeps tracking the driving
expression. Style and liveness compose, so a stylized avatar is still live.

A `model.gltf` node may add `"control": {"orbit", "dolly", "roll"}`, a
turntable the recognized gestures steer: `orbit` spins the model with a drag
(yaw from the horizontal, pitch from the vertical), `dolly` scales it with a
pinch, and `roll` turns it with a two-finger twist. The accumulated transform
multiplies onto the model's pose in its own local frame, before any anchor
places it, so a lens lets a viewer turn a character in the frame. The gestures
are the same `goss_session_touch` input the touch signals read, so a control
and a script can share one input stream.

A `model.gltf` node may instead carry `"physics"`: a rigid body whose
pose drives the model matrix once simulation starts. `body` is `box`,
`sphere`, `cylinder`, `capsule` (the last two axis vertical), `hull`, or
`mesh`, `size` is box half extents (a sphere reads its radius from the
first element; a cylinder or capsule reads radius from the first and half
height from the second), a `hull` instead lists `points` as at least
four `[x, y, z]` and its collider is their convex hull, a `mesh` lists
`points` and `indices` (three per triangle) for a concave collider and is
always static, `position` places the body at activation, an optional
`rotation` in euler degrees lays an elongated body on its side or tilts a
collider, optional `friction` (0 slippery, ~1 grippy) and `restitution`
(0 dead, 1 bouncy) set its surface material, `"planar": true` confines a
body to the z=0 plane (it moves in x and y and spins about z only) for a
2D world laid into the scene, and
`motion` is `dynamic`, `static`, or `kinematic` (the engine holds the
body, so chained content can hang off it). A body may add
`"chain": {"to": "<node id>", "length": <meters>}`, a distance
constraint hanging it off another node's body - earrings off a
kinematic anchor, a pendant off a bead. Adding `"joint": "point"` to
the chain links the two at a pivot the body swings freely about (a ball
joint) instead, `"joint": "fixed"` welds them rigidly so the body rides
the anchor, `"joint": "hinge"` lets it swing about a single axis like a
door or a pendulum, `"joint": "spring"` tethers them softly at `length`
so the body stretches and bobs, and `"joint": "distance"` (the default)
bounds their separation up to `length`. Adding
`"jiggle": {"segments": <n>, "stiffness": <hz>, "damping": <0..1>}` to
the chain instead builds the link from `n` soft springs through hidden
proxy bodies, so the content lags and sways after the anchor moves -
secondary motion for hair, jewelry, and tails. Simulation steps at a fixed
rate from frame timestamps, so the same frames replay the same motion;
on a session without physics support the node holds its initial pose.

A model.gltf node may instead carry a `"cloth": {"cols", "rows",
"width", "height"}` field: the node becomes a simulated cloth sheet
(a grid of the given resolution and world size, top edge pinned)
rather than a glb mesh, its deformed vertices drawn each frame. It
needs no glb asset.

A model.gltf node may instead carry a `"balloon": {"radius",
"subdivisions", "pressure"}` field: the node becomes a closed soft-body
shell (a sphere subdivided from an octahedron) that its internal
`pressure` inflates - a positive pressure puffs it out, zero leaves it
limp. `radius` is the rest size in metres, `subdivisions` (0 to 3) sets
the shell resolution, and `pinned` (default true) holds the top cap so it
hangs; set it false to drop the shell as a free soft body that collides
with rigid bodies and squishes on impact. All are optional with engine
defaults. Like cloth it needs no glb asset.

A model.gltf node may instead carry a `"hair": {"strands", "verts",
"length"}` field: the node becomes a set of simulated hair strands
driven by the tracked head pose and drawn as lines rather than a glb
mesh. `strands` (1 to 256) is how many strands, `verts` (2 to 64) is
the vertices along each, and `length` is how far they hang in meters;
all are optional with engine defaults. Like cloth it needs no glb
asset, and without a tracked head the strands hang from their initial
pose, the standard capability degradation.

A model.gltf node may instead carry a `"particles"` field: the node becomes
a particle system instead of a glb mesh, drawn over the frame. The sim is a
deterministic CPU integration - no clock, no randomness, every particle a
pure function of its index and elapsed steps - so the same field and frame
count produce the same picture, conformance bit-stable; it needs no glb
asset. A `"preset"` names a prebuilt effect from the VFX asset library -
`fire`, `smoke`, `magic`, or `sparks` - that fills in a curated config the
other fields then override, so `{"preset": "fire"}` is a finished flame and
`{"preset": "fire", "count": 400}` is a bigger one. `count` is how many
(1 to 4096); the rest of the field tunes emission, motion, and appearance:

- Emission `"pattern"`: `fountain` (default), `rain`, `burst`, `ring`,
  `cone`, `sphere`, `box`, `disc`, `hemisphere`, or `face` - the last spawns
  from the tracked face landmarks (sparkles off the face), degrading to
  nothing without a tracked subject.
- Motion: `"gravity"`, `"speed"` and `"lifetime"` (each with a 0..1
  `"speed_spread"` / `"lifetime_spread"` to vary it per particle), `"drag"`
  (air resistance), `"wind": [x, y, z]`, `"turbulence"` (swirl), `"curl"`
  (a divergence-free curl-noise swirl, the organic churn of smoke and fire),
  `"attract": [x, y, z]` with `"attract_strength"` (a gravity well),
  `"vortex"` (orbital swirl), `"floor"` (a height particles bounce off),
  `"bounce"` (0..1, how much speed a floor or collider bounce keeps),
  `"colliders": [[x, y, z, radius], ...]` (up to sixteen spheres particles
  bounce off, kept outside each), `"box_colliders": [[x, y, z, hx, hy, hz],
  ...]` (up to sixteen axis-aligned boxes they bounce off), `"plane_colliders":
  [[nx, ny, nz, d], ...]` (up to sixteen infinite planes - walls, ramps, slides
  - they bounce off), and `"oneshot"` (emit once and die out rather than
  looping).
- Appearance (with `"fade": true` each particle is a camera-facing sprite,
  otherwise a one-pixel point): `"size"` px at birth with an optional
  `"size_end"`, `"color": [r, g, b]` crossing to a `"cool"` colour over life,
  `"spin"` turns over life, `"stretch"` along the screen velocity (streaks),
  `"glow": true` for additive blending, a `"sprite": "<stem>"` textured with
  `assets/<stem>.png`, `"frames"` to flip-book through a square sprite sheet
  over life, `"trail"` to draw that many of each particle's recent
  positions as a fading ribbon of billboards behind it (a comet tail),
  `"ribbon": true` to draw that trail history as one solid connected strip
  instead (it needs `"trail"` set for the history), and `"mesh": true` to draw
  each particle as a small 3D shape sized by `"size"` rather than a flat
  billboard, its `"mesh_shape"` one of `"octahedron"` (default), `"cube"`, or
  `"tetra"`.
- Sub-emitter: `"sub_count"` (0 to 64) children each particle bursts into
  when it dies, on an even outward spray, with `"sub_speed"` and
  `"sub_lifetime"` for their launch and life - a firework shell opening into
  sparks. The children fade and fall on their own; pair with `"fade"` so
  spent sparks vanish.
- `"gpu": true` runs the fountain sim on the GPU compute path at crowd scale
  where the backend supports compute; elsewhere the identical CPU sim runs, so
  the same field draws the same picture either way.

A `"blur.pass"` node is a standalone post-effect: it softens whatever frame
reaches it with the engine's built-in separable box blur and passes the
result down the chain, the same primitive `beauty.face`'s smooth step uses,
here exposed as its own node so a lens can blur the full frame without a
beauty filter. It reads `shaders/*.glsl` nothing and ships no asset - the
program is kit-authored and fixed - so it is always ready and never
degrades. Place it anywhere in the chain; it blurs its input and hands the
softened frame to the next node.

A `"grade.pass"` node is a parametric color adjustment post-effect. It
carries a `"grade"` block and shifts whatever frame reaches it, then hands
the graded frame down the chain. The fields are `exposure` (stops),
`brightness` (additive lift), `contrast` and `saturation` (multipliers
around 1), `temperature` and `tint` (the warm/cool and green/magenta white
balance axes), `hue` (degrees of rotation), `grayscale` and `invert` (a
0..1 amount toward black and white or toward the complement), and
`posterize` (a level count, 0 to disable). They apply in that order. Every
field is optional and defaults to the identity, so a `grade.pass` with an
empty block leaves the frame untouched. Like `blur.pass` it ships no asset
and is always ready; it lets a lens warm, cool, brighten, desaturate,
posterize or invert without authoring a LUT.

A `grade` block may also name a `"mask"` channel (one of the segmentation mask
channels, such as `teeth`, `sclera`, or `face_skin`), scoping the grade to that
region: the graded result blends over the original by the channel's soft mask,
so a whitening grade lands on the teeth or a skin-tone lift on the face while the
rest of the frame is untouched. With no `mask` the whole frame is graded.

A `"bloom.pass"` node is a glow post-effect. It carries a `"bloom":
{"threshold", "intensity"}` block: it extracts the frame's highlights - what
sits above `threshold` in luma - blurs them, and adds that blurred glow back
over the frame scaled by `intensity`, so bright areas bleed a soft halo.
Both fields are optional with engine defaults. Like `blur.pass` and
`grade.pass` it ships no asset and is always ready.

A `"dehaze.pass"` node is a single-pass dehaze post-effect. It carries a
`"dehaze": {"strength"}` block (0..1, default 1): a dark-channel-prior estimate
of the atmospheric veil on each pixel drives a transmission recovery that pulls
the scene radiance back out from under it, so a hazy frame gains contrast and
its washed highlights come down. Strength 0 leaves the frame untouched. Like
`grade.pass` it ships no asset and is always ready.

A `"relight.pass"` node is a parametric directional relight post-effect. It
carries a `"relight": {"strength", "angle"}` block: a soft key light from
`angle` (degrees, 0 lights from the right) brightens the frame on the light side
and shades the far side, scaled by `strength` (0..1, default 1). Strength 0
leaves the frame untouched. Like `grade.pass` it ships no asset and is always
ready.

A `"glare.pass"` node is a specular-highlight rolloff post-effect. It carries a
`"glare": {"strength", "threshold"}` block: a pixel whose luma sits above
`threshold` (0..1, default 0.8) is pulled back down toward it by `strength`
(0..1, default 1), so a blown-out specular recovers while the rest of the frame
holds. Strength 0 leaves the frame untouched. Like `grade.pass` it ships no
asset and is always ready.

A `"vignette.pass"` node is a radial luma-gain post-effect. It carries a
`"vignette": {"strength", "radius"}` block: the distance from the frame centre is
rolled in from `radius` (0..1 of the half-diagonal, default 0.5, inside which the
frame is untouched) out to the corner, and that falloff scales the gain
`strength` (-1..1, default 0.5). A positive strength lifts the darkened corners,
correcting a lens vignette; a negative strength sinks them for a stylistic one.
Strength 0 leaves the frame untouched. Like `grade.pass` it ships no asset and is
always ready.

A `"lowlight.pass"` node is a night-mode lift post-effect. It carries a
`"lowlight": {"strength", "denoise"}` block: a shadow-weighted blur of each
pixel's neighbourhood damps the noise that lives in dark regions by `denoise`
(0..1, default 0.5), then a gamma curve raises the shadows by `strength` (0..1,
default 0.6) while holding the highlights near white. With both 0 the frame is
untouched. Like `grade.pass` it ships no asset and is always ready.

An `"undistort.pass"` node is a lens-distortion correction post-effect. It
carries an `"undistort": {"strength"}` block (0..1, default 1) that blends toward
the corrected sample. The radial coefficients and principal point come from the
camera intrinsics the host submits through the ABI, not the manifest: for each
output pixel the sampler reads the input at the radius the true point sits at,
`r_d = r*(1 + k1 r^2 + k2 r^4)`, straightening a barrel or pincushion frame. With
no intrinsics submitted the node is inert. It ships no asset and is always ready.

An `"awb.pass"` node is a one-tap auto-enhance post-effect. It carries an `"awb":
{"strength"}` block (0..1, default 1) that blends in a correction estimated per
frame from a small downsample of the whole frame: gray-world per-channel gains
that pull the average color toward neutral, then an auto-levels stretch that maps
the luma black and white points to the full range. Nothing is authored; the
estimate adapts to the scene. Strength 0 leaves the frame untouched. It ships no
asset and is always ready.

A `"stabilize.pass"` node is an electronic image stabilization post-effect. It
carries a `"stabilize": {"strength"}` block (0..1, default 1) that blends in the
correction. Each frame the engine estimates the global motion since the previous
one, integrates it into the camera path, low-passes that into a smoothed path,
and crops and shifts the frame to hold on the smoothed path instead of the raw
jittery one. The smoothing level rides the recording policy's stabilization knob
(off, standard, cinematic); with it off the node is inert. It ships no asset and
is always ready.

A `"zoom.pass"` node is a digital region zoom post-effect. It carries a `"zoom":
{"factor", "cx", "cy"}` block: the region around the normalized centre (`cx`,
`cy`, default the frame centre) is magnified by `factor` (1..8, default 1) to fill
the frame, so a sub-region fills the output and reads sharper after an upscale
pass downstream. Factor 1 with a centred point is the identity. It ships no asset
and is always ready.

A `"dereflect.pass"` node is a localized specular attenuation post-effect. It
carries a `"dereflect": {"strength"}` block (0..1, default 1): a glass reflection
or glare sits as high-frequency detail over the bright regions of the frame, so
the pass pulls each pixel's detail (its difference from the neighbourhood mean)
back toward that mean, weighted by the pixel's brightness and by `strength`. Dark
regions and strength 0 are untouched. It ships no asset and is always ready.

A `"harmonize.pass"` node is a statistical color transfer between the person and
its background. It carries a `"harmonize": {"strength", "direction"}` block:
`strength` (0..1, default 1) blends the match in, and `direction` (0 or 1, default
0) picks which region is recolored, 0 matching the person to the background and 1
the reverse. It reads the person segmentation mask on the host thread, measures
each region's mean and spread of color from the frame, and applies a Reinhard
transfer (subtract the source mean, scale by the ratio of spreads, add the
destination mean) inside the chosen region, so an inserted subject takes on the
color cast of where it now sits. Without a person mask, or at strength 0, it holds
the frame through, the standard capability degradation. It ships no asset.

A `"inpaint.pass"` node is a content-aware fill. It carries an `"inpaint":
{"mask", "radius"}` block: `mask` names the channel that marks the region to
remove (an object, a blemish, a passerby), and `radius` (0..0.5 of the frame,
default 0.08) how far to search outward for the color that fills it. Each masked
pixel is replaced by the color of the nearest unmasked boundary, gathered along
rays cast outward and weighted by inverse distance, so the hole takes on the
surrounding content while the unmasked pixels hold. With no mask on the named
channel it holds the frame through, the standard capability degradation. It ships
no asset.

A `"dof.pass"` node is a depth-of-field post-effect. It carries a `"dof":
{"focus", "strength"}` block: `focus` is the plane it keeps sharp (0..1 in
the host's submitted depth near..far range) and `strength` how sharply the
frame softens with distance from it, so geometry nearer or farther than the
focus plane blurs while the plane reads crisp. It reads the depth the host
submits; with no depth it holds the frame through, the standard capability
degradation. Both fields are optional with engine defaults, and it ships no
asset.

A `"fog.pass"` node is a depth fog post-effect. It carries a `"fog":
{"color", "density"}` block: the frame fades toward `color` (three 0..1
numbers) by how far its submitted depth is, `density` scaling the falloff,
so distant geometry sinks into haze while near content stays clear. Like
`dof.pass` it reads the host's depth and holds the frame through when none
is submitted, ships no asset, and defaults its fields.

An `"outline.pass"` node is an edge outline post-effect. It carries an
`"outline": {"color", "threshold", "mask"}` block: where the submitted depth,
or a named `mask` channel's edge, jumps between neighboring pixels by more
than `threshold` it draws `color` (three 0..1 numbers) over the frame, so a
silhouette, crease, segmentation class, or face-part matte gets a toon
outline while flat regions stay untouched. With no `mask` it reads the host's
depth and holds the frame through when none is submitted. It ships no asset
and defaults its fields.

An `"occluder.pass"` node is a head occluder for 3D content. It carries an
`"occluder": {"mask", "expand", "softness"}` block: where a named `mask` channel
marks the subject (the `head` matte by default, from the face landmarks) it
reveals the camera frame back over the composited image, so model, particle,
and brush content drawn earlier in the chain reads as sitting behind the head
and is hidden by it, while content after the occluder sits in front and shows.
`expand` grows the revealed silhouette a little (0..0.2 in frame fractions) to
cover content peeking past the matte edge, and `softness` feathers that edge
(0..0.5). The pass adds no color of its own; it only reveals the frame. With no
face the head matte is the zero mask, so it holds the composited frame through.
The engine has no depth attachment on its composite targets and draws 3D
content without a depth test, so occlusion is this screen-space reveal keyed to
the landmark matte, ordered by the chain, rather than a depth-buffer cull.

A `"cutout.pass"` node isolates the face onto a plain background. It carries a
`"cutout": {"color", "mask", "softness"}` block: where a named `mask` channel
marks the subject (the `head` matte by default, from the face landmarks) it
keeps the camera frame through, and everywhere else it replaces the frame with
the flat `color` (three 0..1 numbers), so the face reads on a solid background
of the lens author's choosing. `softness` (0..0.5) feathers the matte edge so
the cut is not jagged. It is the face-matte sibling of `blend.pass`, which swaps
a background image behind the segmented person; a cutout swaps a flat color
behind the landmark face. With no face the matte is the zero mask, so the pass
is not ready and holds the frame through rather than flooding the flat color.

A `"tint.pass"` node is a masked color layer. It carries a `"tint": {"color",
"opacity", "mask", "source", "blend", "finish"}` block: it folds `color` (three
0..1 numbers) into the region a named `mask` channel marks, scaled by the mask
and `opacity` (0..1), so a face-part matte or a segmentation class reads as soft
makeup. `blend` picks how the color folds in: `normal` (the default) blends
straight toward the color for flat makeup, `multiply` darkens through it for a
contour shadow, and `screen` lightens through it for a highlight, the two
folds keeping the skin texture a flat blend would wash out. With
`"source": "reference"` the color comes from the makeup reference set through
the ABI for that channel instead of the static rgb. The reference samples the
lips, eyes, brows, and a cheek-and-forehead skin patch, so a foundation over
`face_skin` matches the reference's skin tone. A tint naming no mask, or
a channel the running lens never fills, serves the zero mask and draws
nothing.

`finish` sets the surface the layer wears within the mask. A 2D camera makeup
has no per-pixel face normal, so the finish reads its light from the frame's own
highlights inside the region. `matte` (the default) is the flat blend above,
byte-for-byte the plain tint. `gloss` lifts the region's existing highlights
into a soft specular sheen, so a lit lip catches more light. `shimmer` adds a
stable, screen-locked micro-glint that sparkles the highlights, deterministic
across frames and runs with no runtime randomness. `metallic` drives a stronger
contrast and chroma boost with a harder specular follow for a metallic read.
Every finish scales with the mask, so it fades to nothing where the region does,
and `matte` leaves the flat layer untouched. `none` is accepted as a synonym for
`matte`.

The eye makeup keyed to `eyes` is eyeshadow, filling the whole lid. Eyeliner,
mascara, and false lashes instead key `lash_line`, the thin band each eye's
upper lid arc rises into just above the lash line, derived from the eye contour
landmarks. One band serves all three: they are the same masked tint at
increasing weight, an eyeliner a light dark line, mascara a heavier darkening,
false lashes the densest, so the band shape stays fixed and the tint color and
opacity set the look. The `eyeliner`, `mascara`, and `false-lashes` reference
lenses each multiply a near-black into that band. A denser 3D lash mesh pinned
to the eye landmarks is a separate mesh form, not this masked tint.

A `"smooth.pass"` node is a masked detail pass. It carries a `"smooth":
{"amount", "mask"}` block: it mixes the masked region toward a small neighbor
average by `amount`, so a positive amount blurs (skin smoothing) and a
negative one (down to -1) sharpens. It keys the same mask channels as
`tint.pass`; a smooth naming none is inert. Keyed to `body_skin` or `person` it
evens body skin without touching the background, the retouch companion to the
mask-gated body reshape above.

A `"retouch.pass"` node is a masked selective skin filter, a stronger companion
to `smooth.pass`. It carries a `"retouch": {"mode", "amount", "mask"}` block.
`mode` is `blemish`, a wider edge-aware average that evens small spots while a
real edge (a lid, a brow) keeps its own tone so skin texture survives, or
`shine`, which pulls pixels brighter than their local mean back toward it to
matte a specular highlight. `amount` (0..1) scales the effect. It keys the same
mask channels as `tint.pass`; a retouch naming none is inert. The retouch looks
pair it with the landmark regions below: blemish over `face_skin`, shine over
`t_zone`.

A `"paint.face"` node lays a lens image onto the tracked face. It ships its
texture as `assets/<id>.png` and warps it over the face through the canonical
face mesh UVs the way `mesh.face` does, so the image tracks and deforms with the
face. It carries a `"paint": {"mask", "opacity", "blend"}` block: `opacity`
(0..1) scales how strongly the image sits on the skin, `mask` names a face
channel the image is confined to within the mesh (`face_skin` for paint that
skips the eyes and lips, a face-part region like `contour` for a tighter decal),
and `blend` folds the image onto the skin the way `tint.pass` folds a color:
`normal` (the default) lays it straight over for face paint, `multiply` darkens
the skin through it for an ink tattoo, and `screen` lightens through it. With no
`mask` the image covers the whole face mesh, a full-face image projection. Where
the image's own alpha is zero the skin shows through, so a painted design or a
tattoo decal reads as sitting on the face rather than a flat overlay. Without a
tracked face the node draws nothing, the standard capability degradation; a
named region with no live data serves the zero mask, so the paint fades there.
The `face-projection`, `war-paint`, and `face-tattoo` reference lenses show the
whole-face projection, the skin-masked paint, and the region-masked ink.

A `"face.swap"` node warps a donor face onto the tracked face. It ships the
donor as `assets/<id>.png`, a face baked into the canonical face-mesh UV layout
the same way `paint.face` and `mesh.face` read their textures, so the donor
samples through the mesh and tracks and deforms with the live face. It carries a
`"swap": {"opacity", "feather", "mask"}` block: `opacity` (0..1) scales the swap
strength, `feather` (0.02..1) sets the seam softness, and `mask` optionally
names a face channel the swap is further confined to within the mesh. The engine
carries a per-vertex seam weight that is zero on the face silhouette and rises to
one in the interior; the fragment stage ramps the swap alpha over the `feather`
band of that weight, so the donor fades into the surrounding skin at the boundary
instead of ending on a hard mesh edge. With no `mask` the face mesh and its
feather define the region, and where the donor's own alpha is zero the live skin
shows through. Without a tracked face the node draws nothing, the standard
capability degradation. The `face-swap` reference lens shows the feathered swap
on a tracked face.

A `"mesh.lashes"` node rises a 3D lash strip off each eye's upper lid, the mesh
sibling of the flat mascara and false-lash tints. It ships no asset: the strip
is a thin ribbon whose base pins to the upper lash-line landmarks and whose tip
row is rebuilt from the tracked eye landmarks each frame, so the lashes track
and deform with the eye. It carries a `"lashes": {"color", "opacity", "length",
"curl"}` block: `color` (rgb, 0..1) and `opacity` (0..1) tint how the strands
blend over the frame, `length` (0..2) is how far each strand rises off the lid
and `curl` (-1..1) how far its tip sweeps toward the outer corner, both as
fractions of the eye's own height so the strip scales with the face. The
fragment stage combs the ribbon into individual strands that narrow to a point
at the tip. Without a tracked face the node draws nothing, the standard
capability degradation. The `lashes-3d` reference lens shows the strip on a
tracked face.

A `"matte.refine"` node refines a segmentation matte's edges against the
frame. It carries a `"matte": {"radius", "sensitivity", "strength", "mask"}`
block and runs a guided (joint-bilateral) filter: the frame luminance is the
edge guide, so where the frame has a strong luma edge the matte's alpha snaps
to it, and in flat regions the matte is smoothed. `radius` (0.5..6) sets the
neighborhood reach, `sensitivity` how hard a guide difference rejects a
neighbor across an edge, and `strength` (0..1) how far the output moves from
the input matte toward the refined one. `mask` picks the channel it refines -
`hair` lifts a coarse hair matte toward the crisp strand boundary the frame
carries; a node naming no channel refines the submitted depth instead. The
output is the refined matte as grayscale.

A `"matte.hair"` node is a dedicated high-resolution hair matte source. It draws
nothing itself and passes the frame through; each frame it refines the coarse
`hair` segmentation class against the camera luminance through the same guided
joint-bilateral filter `matte.refine` uses, then publishes the result as the
`hair_matte` channel. A hair effect keys `hair_matte` for a soft, strand-level
alpha with a feathered edge instead of the hard coarse `hair` bit. It carries a
`"hair_matte": {"radius", "sensitivity", "strength"}` block with the same
guided-filter meaning `matte.refine` gives them, all optional with engine
defaults. Without the coarse `hair` class (no segmentation, or a model without
the class) the published channel is the zero mask, so a hair pass keyed to it
fades to nothing, the standard capability degradation. The `hair-matte` reference
lens recolors hair through the refined channel.

A `"stylize.pass"` node is a single-pass artistic filter over the whole
frame. It carries a `"stylize": {"mode", "strength", "threshold", "levels"}`
block: `mode` is `sketch` (a pencil edge over pale paper), `toon` (color
quantized to `levels` with edges past `threshold` knocked to black), `emboss`
(a mid-gray relief), or `crosshatch` (ink hatching keyed by luminance).
`strength` scales the edge or emboss response. It reads no host input, ships
no asset, and is always ready.

An `"edge.pass"` node is an edge-detection post-effect over the whole frame. It
carries an `"edge": {"mode", "low_threshold", "high_threshold", "blur_radius",
"strength", "invert"}` block. `mode` is `sobel` (a single-pass 3x3 gradient
magnitude, its brightness scaled by `strength`) or `canny` (a blur, a
directional sobel, non-maximum suppression and weak-pixel hysteresis chained
into thin binary edges). `low_threshold` and `high_threshold` are canny's
hysteresis band and `blur_radius` its pre-blur width in texels; sobel ignores
all three. `invert` draws dark edges on a light field instead of light on dark.
It reads no host input, ships no asset, and is always ready.

A `"warp.pass"` node is a geometric distortion over the whole frame, radial
around a center within a radius. It carries a `"warp": {"mode", "center_x",
"center_y", "radius", "strength", "refractive_index", "aspect_auto", "symmetry",
"symmetry_x", "points", "mask"}` block. `mode` is `glass_sphere` (a glass lens that
refracts the frame through a sphere and lets the surround through),
`sphere_refraction` (the same refraction but the classic crystal ball, black
outside the sphere), `bulge` (magnify toward the center), `pinch` (pull the
image inward), `swirl` (twist about the center), `liquify` (freeform
multi-point push/pull), or `face_scale` (scale the whole tracked face about its
own center). `center_x` and `center_y` place the distortion, `radius`
sizes it, and `strength` scales how hard it pushes, with zero an identity.

`face_scale` is a landmark-anchored transform: it ignores the static center and
radius and takes both from the tracked face each frame, then scales the face
region about its own centroid. `strength` reads as a signed scale here, so a
positive value enlarges the face (a stretch) and a negative one shrinks it (an
inset), easing to identity by the region's rim so the surround is untouched. It
needs a tracked face like `reshape.bank`; with no face it holds the frame
through. The `face-inset`, `face-stretch`, and `face-cutout` reference lenses
show the three landmark-anchored face transforms.
`refractive_index` is the glass index the two sphere modes bend the view ray by;
the displacement modes ignore it. `aspect_auto` keeps the region circular on
screen by correcting for the frame's aspect.

`symmetry` mirrors the displacement across the vertical axis at `symmetry_x`, so
an off-center warp reshapes both sides at once; it applies to the bulge, pinch,
swirl and liquify modes, not the sphere refractions. `liquify` reads a `points`
array of up to eight push points, each `{"x", "y", "dx", "dy", "radius"}`: `x`
and `y` place it, `dx` and `dy` are the push direction scaled by magnitude, and
`radius` is the falloff the push fades to zero at. The pushes sum with a smooth
falloff, so several local points reshape freeform rather than around one radial
center. It reads no host input, ships no asset, and is always ready.

`mask` names a segmentation class the displacement is confined to. Only pixels
the mask marks move; the rest stay exactly where they were, so a body-slim (a
`person` or `body_skin` pinch over the torso) narrows the subject and leaves the
background behind them undistorted. Named but with no live class the warp moves
nothing; omitted, it warps the whole frame, byte for byte as before. It keys the
same channels as the masked color and retouch passes below.

A `"reshape.bank"` node is a landmark-driven face sculpt: sixty-six per-region
deformations that warp the frame around the tracked face and decay to identity
away from each region, so one bank never bleeds into another. It carries a
`"reshape"` block whose fields each take a value in `[-1,1]` with `0` the
identity, grouped by region: nose (`nose_width`, `nose_bridge_width`,
`nose_bridge_height`, `nose_tip_size`, `nose_tip_height`, `nose_length`,
`nostril_size`, `nose_scale`), jaw (`jaw_width`, `jaw_slim`, `jaw_left`,
`jaw_right`, `jaw_angle`, `jaw_height`, `jaw_v_line`), chin (`chin_length`,
`chin_width`, `chin_point`, `chin_height`, `chin_forward`, `chin_size`), lip
(`lip_size`, `lip_width`, `lip_height`, `lip_upper`, `lip_lower`,
`mouth_position`, `mouth_corner`, `cupid_bow`, `philtrum_length`), cheek
(`cheek_fullness_l`, `cheek_fullness_r`, `cheek_slim_l`, `cheek_slim_r`,
`cheekbone_height`, `cheekbone_width`, `cheek_lower_slim`, `cheek_scale`), brow
(`brow_height_l`, `brow_height_r`, `brow_tilt`, `brow_thickness`,
`brow_distance`, `brow_peak`), forehead (`forehead_height`, `forehead_width`,
`forehead_round`, `forehead_size`), eye (`eye_size_l`, `eye_size_r`,
`eye_width`, `eye_height`, `eye_distance`, `eye_tilt`, `eye_inner_corner`,
`eye_outer_corner`, `eye_lower`, `eye_scale`) and whole face (`face_slim`,
`face_width`, `face_length`, `face_v_shape`, `temple_width`, `face_scale`,
`face_symmetry`, `face_overall`). Every field is optional and defaults to zero.
It reads the tracked face landmarks, so it declares the `face` capability and
holds the frame through untouched without a tracked face, and it ships no asset.

A `"trail.pass"` node is a motion-trail post-effect. It carries a `"trail":
{"amount"}` block: `amount` (0..1) is how much of the previous frame the
current one keeps, so moving subjects smear a fading echo behind them while a
still frame is left untouched. It needs no host input - the frame it echoes is
the one it drew last, seeded from the current frame the first time so the first
frame shows no echo - so it is always ready. `amount` is optional with an
engine default, and it ships no asset.

An `"ssr.pass"` node is a screen-space reflection post-effect. It carries an
`"ssr": {"strength", "plane"}` block: `plane` (0..1 down the frame) is the
horizon below which the scene mirrors into a reflective floor, and `strength`
(0..1) how strongly the reflection shows. It reads the host's submitted depth
to scale the reflection by how near the floor is, so a near floor wets while a
far one stays dry, holding the frame through when no depth is submitted. Both
fields are optional with engine defaults, and it ships no asset.

An `"env.pass"` node draws the environment behind the segmented foreground.
It carries an `"env": {"top", "bottom", "intensity"}` block: a gradient from
`bottom` to `top` (each three 0..1 numbers) scaled by `intensity`, with a sun
glow, standing in for the environment behind the subject. It composites over
the segmentation mask the way `blend.pass` does, so the environment fills the
background and the subject stays put; the submitted camera pose pans it as the
device turns. If the node ships an equirect image at `assets/<id>.png` it
samples that panorama by the pose-turned view ray instead of the gradient,
upgrading in place once the image loads. With no segmentation the mask defaults
to all-foreground and the environment stays hidden. The color fields are
optional with engine defaults, the image is optional, and it declares the
`"segmentation"` capability.

A `"draw.board"` node draws the session's brush board at its own place in the
chain: the frame passes through, then every committed stroke draws over it, neon
strokes additively and the rest on alpha. It ships no asset, carries no params,
and is always ready, since the strokes come from the host's draw input, not the
bundle. Without a `draw.board` node the board still draws as a final overlay; the
node only lets a lens place it earlier so later passes act on the drawing too.

A `"sprite.2d"` node draws a 2D image over the frame at its own place in the
chain. It ships its image as `assets/<id>.png` and carries a `"sprite":
{"x", "y", "w", "h", "opacity"}` block: a rect in normalized frame
coordinates (origin top-left, 0..1 across the frame) and a draw opacity,
all optional and defaulting to the full frame at full opacity. The image
alpha-composites within the rect over whatever the chain has drawn so far,
so a sprite reads as a sticker or badge pinned to the frame. An
`"opacity_param"` names a parameter whose live value overrides the opacity
each frame, so a param_ramp fades the sprite or a beat trigger pulses it.
`"x_param"`, `"y_param"`, `"w_param"`, and `"h_param"` do the same for the
rect: each names a parameter whose live value overrides that axis each frame,
so a value flowing into it moves and sizes the sprite. An unbound axis keeps
its static value. This is how a lens anchors a sprite to something a model
found: an `ml.infer` node writes a detected box's center or a tracked
keypoint's position into a parameter, and the sprite bound to it follows.
A `"frames"` count above one makes the sprite animated: it loads
`assets/<id>_0.png` through `assets/<id>_(frames-1).png` and cycles them at
`"fps"` off the lens clock. Shipping the image as an animated GIF at
`assets/<id>.gif` instead plays the clip as a video texture: the engine
decodes its frames and cycles them at the clip's own frame timing, so a
sticker animates without a param or a frame count. Until its image decodes
(all frames, for an animated sprite) the node holds the frame through, never
blocking the chain.

A `"mask"` names a segmentation channel and keys the sprite full-frame against
the region it marks, composited the way `blend.pass` swaps a background. A
`"mask_mode"` picks the side: `"behind"` (the default) fills the sprite where
the channel is off and shows the camera where it is on, a greenscreen behind the
subject; `"over"` fills the sprite where the channel is on and shows the camera
where it is off, a restyle of that region. It keys any sprite source the same
way, so a bundled image, a video, or a generative texture (a diffusion or
`ml.infer` style node targeting the sprite) becomes the replaced content:
`"mask": "person"` restyles the room behind a selfie, and `"mask": "face_skin",
"mask_mode": "over"` lays a generative restyle onto the face and nowhere else.
With no live segmentation the sprite stays hidden and the camera holds through,
either way. A sprite with no `mask` draws over the frame at its rect as usual.

In `over` mode a `"mask_strength"` (0 to 1, default 1) mixes the restyle onto its
region: 1 is the full restyle, 0 holds the camera, and a value between is a
partial blend, so a de-age, beauty, or harmonization restyle dials in by degree.
`"mask_strength_param"` binds it to a live parameter for a slider. `behind` mode
ignores it and keys at full strength (a greenscreen is not a partial blend).

A sprite carries an optional `"interaction"` block so a finger can move it:
`{"drag", "pinch", "rotate", "tap_event"}`. With `"drag"` a single finger that
goes down on the sprite slides it, with `"pinch"` two fingers scale it about
its centre, with `"rotate"` two fingers turn it, and `"tap_event"` names an
event the engine fires when a tap lands on the sprite, delivered to
`event('name')` triggers and the script's `onEvent` the same tick, so a lens
reacts to the object being tapped. The recognized gestures come from
`goss_session_touch`; a sprite names only what it wants.

The same block composes screen UI. A tap event makes the sprite a button. With
`"slider_param"` the sprite becomes a slider handle: a drag runs it along a
track from `"slider_min"` to `"slider_max"` (normalized, `"slider_vertical"`
for a vertical track) and writes its 0..1 position to that parameter each tick.
With `"carousel_param"` and `"carousel_count"` a swipe steps an index parameter
over the item count, so a swipe left advances and a swipe right goes back. The
parameters drive the rest of the lens, so a slider fades an effect or a
carousel selects a look with no script.

A `"text.2d"` node draws a line of text over the frame. It carries a `"text":
{"content", "x", "y", "w", "h", "opacity", "color"}` block: the string to
draw, the same normalized rect and opacity a sprite takes, and an rgb color
(three 0..1 numbers) for the glyphs. The engine rasterizes the string with a
built-in font, so a text node ships no asset, and composites it into the rect
like a sprite; it takes the same `"opacity_param"` for a parameter-driven
fade. A newline in the `content` starts a new line, so a multi-line caption
fits the rect as several rows. The font covers space, digits, upper- and
lowercase letters, and common punctuation; any other character draws blank.
The text block also styles the glyphs: `"gradient"` (an rgb the glyphs fade
toward at their base, the top staying the main color), `"shadow"` (a soft
drop shadow), `"stroke"` (an rgb outline), and `"depth"` (a value above zero
extrudes the glyphs into a rotated 3D block mesh rather than flat sprite text).

A `"video.texture"` node plays an MP4 clip over the frame like a sprite. It
ships its clip as `assets/<source>.mp4` and carries a `"video": {"source",
"x", "y", "w", "h", "opacity", "fps", "loop"}` block: the asset stem, the same
normalized rect and opacity a sprite takes, the playback rate the clip advances
at off the frame clock, and whether it loops. The engine decodes the clip off
the platform's hardware decoder, streaming the next frame onto the sprite one
frame at a time, so playback stays O(1) per frame rather than reopening the
file. `"fps": 0` holds the first frame; `"loop": false` holds the last frame at
the end instead of rewinding. Targets without a hardware decoder play a
deterministic synthetic clip so the node still runs.

A `"splat.cloud"` node draws 3D geometry a bundled model lifts from a frame.
It carries a `"splat": {"model", "source", "draw", "point", "r", "g", "b",
"colored"}` block: `model` names the net under `assets/`, whose output is a flat
list of xyz positions (its length a multiple of three, one point per triple).
With `"colored"` the model emits rgb after xyz per point (its length a multiple
of six) and each splat draws in its own color instead of the node `r`, `g`, `b`,
so a photoreal selfie avatar carries the photo's color per point. `"source"`
picks the input: `"camera"` (the default) lifts the live frame each tick;
`"selfie"` runs the model once over a still submitted through
`goss_session_submit_avatar_source` and then holds the result, so a photoreal
avatar is generated from one photo and stays put off the live camera. `"draw"`
picks the form: `"points"` (the default) draws camera-facing billboards, a splat
cloud, sized by `"point"` (pixels); `"mesh"` reads the output as a square grid and
draws it as a connected 3D surface, one quad per grid cell. `r`, `g`, `b` are the
color. The model runs on the inference rail like any author model, off the frame
thread; the engine reads its latest points and draws them in a perspective view,
so the submitted camera pose orbits the geometry. Until the model produces its
first points the node holds the frame through, the standard capability
degradation. This is the text-to-3D and selfie-avatar path: an image-to-geometry
net turns a frame or a photo into a splat cloud or a mesh surface the lens
composites like any other draw.

A `"layout.composite"` node lets a lens drive the head composite instead of the
host: it carries a `"layout": {"arrangement", "key", "chroma", "similarity",
"opacity"}` block where arrangement is one of `custom`, `side_by_side`,
`top_bottom`, `pip`, `grid`, `overlay`, and key is `none`, `matte`, or `chroma`
for the camera base's blend. The app still supplies the source media; the lens
only arranges it. The node configures the composite at the head of the chain, so
it never draws as a chain pass, and the arrangement clears when the lens changes.

A `"script"` node carries an inline `"source"` string of JavaScript that
defines a global `update(lens)` function. It draws nothing and never joins
the composite chain; instead the host runs it once per tick, before triggers
and ramps, exposing the current signals as `lens.signals.<name>` (read) and
the lens parameters as `lens.params.<name>` (read and write). The signal
surface is the live signals (`face_present`, `hands_present`, `audio_level`,
`audio_beat`, `world_tracking_state`, `tap`), the screen gestures
(`touch_double_tap`, `touch_long_press`, `touch_swipe`, `touch_drag`,
`touch_pinch`, `touch_rotate`, `pointer_x`, `pointer_y`), and every ARKit
blendshape by name (`lens.signals.jawOpen`, `mouthSmileLeft`, and the rest),
so a script reacts to an expression the way a trigger reads `jawOpen.blendshape`. Whatever it
writes to a parameter flows into that tick like any other parameter change.
The runtime is sandboxed and deterministic: no filesystem, network, wall
clock, or randomness is in scope (`Date` and `Math.random` are removed), and
each tick is bounded by a fuel limit, so a script can neither reach outside
the lens nor hang the frame. The same inputs always produce the same writes,
which is what lets a scripted lens be conformance bit-stable.

The script's own top-level state persists across ticks, since the context
lives for the life of the lens. A script keeps counters, ring buffers of past
values, or entity-and-component tables in ordinary globals and carries them
frame to frame, so persistent local state and an ECS-style organization are a
matter of how the script is written, not a separate engine feature. A no-code
lens reaches for the counter actions and `counter('name')` instead.

A `logic.graph` node is visual scripting over the same runtime: a small graph
of value nodes that reads the signals and writes a parameter each tick, with no
code. It carries a `"graph": {"nodes", "output", "output_param"}` block. Each
node has an `"id"` and an `"op"`: a leaf reads the world with `signal` (its
`"signal"` is any trigger signal expression, `pointer.x` or `counter('score')`)
or `param` (its `"param"` names a parameter), or is a `const` with a `"value"`.
The rest combine earlier nodes: `add`, `sub`, `mul`, `div`, `min`, `max`,
`clamp`, `lerp`, `gt`, `lt`, `eq`, `and`, `or`, `not`, and `select` (a ? b : c).
An input `"a"`, `"b"` or `"c"` is either a number literal or the id of an
earlier node, so a graph reads only what comes before it. `"output"` names the
node whose value flows to `"output_param"` each tick, evaluated before the
triggers so they read its fresh value. The graph is pure and deterministic, so
a logic-driven lens stays conformance bit-stable like a trigger or a script.

Alongside `update`, a script may define event handlers the engine calls when
a moment happens: `onInit` and `onTurnOn` once when the lens activates,
`onTurnOff` when it deactivates, `onTap`, `onDoubleTap`, `onLongPress`,
`onSwipe`, `onPinch` and `onRotate` when the matching screen gesture is
recognized, and `onEvent(lens, name)` for each host event fired that tick
(the same names `event('name')` triggers read). Every handler receives the
same `lens` with its signals and params, and a handler the script omits is
simply not called, so a lens wires only the moments it cares about.

An `ml.infer` node runs a model the lens ships and turns its output into lens
state. Like `script` and `logic.graph` it draws nothing and never joins the
composite chain; it carries an `"ml"` block whose `"model"` names a file under
`assets/` in the bundle. The file is a TFLite (LiteRT) or ONNX net, chosen by
its own bytes, and it takes one square RGB image the engine fills by sampling
the camera frame into the model's input at whichever channel order the model
declares. Inference runs off the frame thread, so a heavy model never blocks
the render loop; the bindings below read the newest completed result and hold
their default until the first one lands. An author model is untrusted content
like the rest of the bundle: its size, tensor count, and tensor sizes are
bounded, and every value read back is finiteness-guarded, so a hostile or
oversized model fails to load rather than reaching the frame.

The heavy inference workers a lens loads - `ml.infer` nets, diffusion restyles,
and `splat.cloud` clouds - share one per-session budget, so a lens stacking many
nets loads only up to the budget and leaves the rest inert rather than
oversubscribing the device and overheating it. When an enhance chain does stack
these deterministic post-effects, the engine draws them in a fixed order that
keeps each one working on the input it expects: geometry first (undistort, then
stabilize), then resolution (super-resolution), then cleanup (denoise, dehaze,
low-light), then tone (grade, auto white balance), then relight and harmonize,
and beauty last.

The `"outputs"` array binds scalars from the model into parameters. Each entry
names a `"param"` and reads from output `"tensor"` (default 0) either the value
at `"index"` (the default `"reduce"` of `"element"`) or, with
`"reduce": "argmax"`, the index of the tensor's largest element - a
classifier's predicted class. The value is written to the parameter each
inference, clamped to the parameter's declared range like any other write.
A detector or a pose model reaches a lens through these bindings too: it
writes a detected box's coordinates or a keypoint's position into parameters,
and a sprite's placement parameters (or a shader) read them to follow the
found object.

An `"audio.infer"` node is the microphone sibling of `ml.infer`: it runs a
bundled model whose one input is a window of the latest microphone samples
(mono, drawn from a ring the engine fills as audio arrives) and binds the model's
scalar outputs into parameters through the same `"outputs"` array. It carries an
`"audio"` block, `{"model", "outputs"}`, draws nothing, and drives the lens from
sound the way `ml.infer` drives it from the camera - an audio-reactive parameter,
a viseme for a talking avatar, a caption. It is bounded and sandboxed like every
author model, and it counts against the same per-session heavy-worker budget.

An `audio.infer` node may carry a `"caption"` block, `{"tensor", "labels"}`, that
greedy-CTC-decodes an output tensor of `[timesteps, vocab]` logits into text (per
timestep the argmax class, dropping the blank at index 0 and collapsing
consecutive repeats), mapping the surviving classes to a bundled labels file
(`assets/<labels>.txt`, one label per line, the blank first). The decoded text is
read back through the ABI by the node's id, for the app to draw as a live
subtitle. It may also carry a `"diarize"` block, `{"embed_tensor", "max_speakers",
"threshold", "param"}`, that clusters a speaker-embedding output: each embedding
is cosine-matched against a bounded set of speaker centroids, matching the nearest
within `threshold` (and updating it) or allocating a new speaker up to
`max_speakers`, and the matched speaker index drives `param`.

For translation the node's model is the encoder and a `"translate"` block,
`{"decoder", "tokens", "memory_tensor", "max_tokens", "bos", "eos"}`, names a
second bundled decoder step model. The engine runs a greedy autoregressive loop:
it feeds the encoder memory and the previous token (starting at `bos`) to the
decoder each step, takes the argmax, and stops on `eos` or after `max_tokens` (a
fixed-iteration bound, so it never hangs), detokenizing the tokens through a
bundled `tokens` file into the recognized text, read back through the caption ABI
like any other caption.

An `audio.infer` node may also carry a `"dub"` block, `{"model", "rate"}`, naming
a bundled text-to-speech model. When the host enables dubbing through the ABI and
the node's decoded caption or translation changes, the engine feeds the text to
the model, synthesizes the output PCM to speech, and plays it into the lens mixer
at `rate`, so the audio the SDK pulls carries the voice-over. Dubbing is off by
default, since a dub speaks over the room.

An `ml.infer` node may also carry a `"mask"` block, `{"tensor", "channel"}`,
that binds a whole output tensor as a segmentation mask. The tensor is read as
a square single-channel image, resampled to the engine's mask resolution, and
fed to the named mask `"channel"` (the same channel names the beauty and shader
passes key against), so a lens author's own segmenter drives the identical
compositing the built-in segmenters do. A model whose bound tensor is not a
square single-channel plane keeps driving its parameters and feeds no mask.

An `ml.infer` node may carry an `"aux": {"reference"}` block for a model that
takes a second input: a bundled reference image (`assets/<reference>.png`)
sampled into the model's second square-RGB input every inference, so a net is
conditioned on a reference (a makeup, style, or identity transfer). A model that
declares two inputs requires the reference and is otherwise rejected at load; a
one-input model ignores the block. The frame is always the first input.

The second input may instead be the previous output frame, through
`"aux": {"temporal": true}`. The engine holds the last frame's sampled plane and
feeds it into the model's second input each inference, so a recurrent net fuses
the current frame with the one before it (temporal denoise, upscale, or
stabilize). The second input must be the same square size as the first; the very
first frame is its own previous, so a cold start is not a black plane.
`temporal` and `reference` are mutually exclusive.

An `ml.infer` node may carry a `"style"` block, `{"tensor", "sprite"}`, for a
model that restyles the whole frame. The tensor is read as a square
three-channel image, and each inference uploads it to the texture of the
`sprite.2d` node named by `"sprite"`, so that sprite draws the model's output.
A full-frame sprite makes the restyled frame the picture; a placed or
partly-opaque sprite blends it in. The sprite ships no image of its own; its
picture is whatever the model last produced. This is the neural style-transfer
path: a restyle net loads like any other author model, runs off the frame
thread under the same bounds, and draws through the sprite the composite chain
already knows how to place, turn, and fade.

The style output is read at whatever square side the model emits, so the same
binding carries an enhancement whose output is larger than its input: a
super-resolution, denoise, deblur, dehaze, or glare-removal net draws its result
through the sprite at the enlarged side. The preview draws it at the swap chain's
size, so the extra detail of an upscale is fully preserved down the capture path;
pair a super-resolution lens with a high-resolution capture to keep it.

A `"diffusion"` node runs an on-device latent-diffusion restyle. Like the other
behavior nodes it draws nothing itself; it carries a `"diffusion"` block naming
the models the bundle ships under `assets/`: a `"unet"` (the denoiser), a
`"decoder"` (a VAE that turns a latent back into an image), and an optional
`"encoder"` (a VAE that turns the frame into a latent). With an encoder the node
restyles the camera frame (image to image); without one it starts from pure
seeded noise and generates a still (text to image), sized by the decoder. When
an encoder is present the engine samples the camera square into it each frame,
seeds the latent with deterministic noise up to the `"strength"` (0 keeps the
frame, 1 fully restyles); with no encoder it seeds the whole latent from noise
and denoises the full range. It then runs `"steps"` denoise
steps of the UNet on a fixed few-step schedule, and decodes the result. The
UNet reads the latent, and, if it declares them, a timestep and a conditioning
input; a `"text_embedding"` file supplies that conditioning, so a prompt encoded
ahead of time steers the restyle. A `"seed"` fixes the noise, so the same lens
and frame restyle the same way every run. A `"coherence"` (0..1) turns on a
temporal filter: the engine estimates the optical flow between the last camera
frame and this one, warps the previous restyled frame by it so it lands aligned
with the current one, and blends the fresh decode toward that warped history by
the coherence amount. A per-frame restyle then holds steady where content is
still and follows it where it moves, killing the flicker an independent
frame-by-frame restyle shows. It applies to the image-to-image path only, where
there is a moving camera to track; the flow runs at the decoder's resolution.
The decoded image draws through the
`"sprite"` the block names, the same way the style binding does, so the restyle
composites like any other sprite. The loop runs off the frame thread and never
blocks the render; the models are bounded and sandboxed like every author model.

The set of known `type` values is closed and versioned with the *engine*, not
the format - GLF 1.0 does not let a lens introduce a new node type, only
compose the runtime's built-in ones (capture input, the beauty nodes, shader
passes reading `shaders/*.glsl`, the post-effect passes blur/grade/bloom/
dof/fog/outline/tint/smooth/matte/stylize/edge/warp/trail/ssr/env, the
`matte.hair` hair matte source, glTF model
draws, LUT passes, compositing,
the draw board, the layout composite, the 2D sprite, the 2D text, the
`video.texture` node, `mesh.face` - the canonical face mesh warped by the tracked landmarks,
textured by `assets/<id>.png` in canonical UV space with v measured from
the bottom, or by a generative node's output when a diffusion or `ml.infer`
style node targets it, so a prompt-generated image lands as the face material
(a text-to-material on the face mesh); without a tracked face the node draws
nothing, the standard
capability degradation - `paint.face`, the same face-mesh texture warp
masked to a face region and blended onto the skin by opacity and mode,
`face.swap`, a donor face warped through the mesh and feathered into the
surrounding skin at the silhouette, and
`mesh.lashes`, a 3D lash strip rising off each tracked upper lid).
Splice happens once, at lens activation, not per frame; unsplice reverses
it exactly, freeing every resource the splice allocated. Both are edit-time
operations on the graph's edit-time API, never touching the frame-time
path.

## 6. Triggers

A trigger binds a signal expression to an action, evaluated once per frame,
O(1) per trigger with no allocation. An action fires once, on the frame
the expression transitions from false to true - not on every frame it
holds true. A level-triggered `param_ramp` would restart its ramp from
wherever the in-flight value currently sits every single frame and never
converge on its target; edge-triggered firing is the only reading under
which the curve primitives in 6.3 behave as described.

```jsonc
{
  "when": "face.blendshape('jawOpen') > 0.6",
  "action": { "kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200 }
}
```

### 6.1 Expression grammar

The `when` field is not a scripting language; it is one production from a
small closed grammar, parsed once at load time into a typed expression tree
(no runtime parsing, no `eval`):

- Signal reads: `face.blendshape('name')`, `face.present`, `hands.present`,
  `hands.gesture('name')` (true while a tracked hand shows the named canned
  gesture: None, Closed_Fist, Open_Palm, Pointing_Up, Thumb_Down, Thumb_Up,
  Victory, ILoveYou; an unknown name is a compile error), `hands.pinch` (true
  while a tracked hand's thumb and index tips are closed together),
  `world.tracking_state`, `audio.level`, `audio.beat` (true exactly on
onset hops), `camera.zoom` (the camera zoom factor, one at rest),
  `camera.focus`, `camera.exposure` (true for one tick after the app changes
  focus or exposure), `gaze.x` (horizontal eye gaze, roughly -1 to 1,
  positive toward the subject's left), `gaze.y` (vertical, positive up),
  `gaze.at_camera` (true when gaze is near centre; a lost face reads false),
  `head.nod` / `head.shake` (true for one tick when a nod or shake completes),
  `head.tilt` (head roll in radians, positive tipping to the subject's left),
  `body.present` (true while a body is tracked), `body.bone_angle('name')` (the
  bend angle in radians at a named bone: left_elbow, right_elbow, left_knee,
  right_knee, left_shoulder, right_shoulder, left_hip, right_hip; zero folded,
  pi straight, and zero with no body, so gate with `body.present`),
  `body.jump` / `body.wave` (true for one tick when a hop or a raised-hand wave
  completes), `body.dance` (true while rhythmic whole-body motion lasts),
  `timer('name')` (seconds since the
  timer's last reset, see actions below), `device.in_volume` (true while the
  tracked device is inside the lens's `volume` region, see below), `tap`,
  `touch.doubleTap` / `touch.longPress` (true for one tick when the screen
  gesture completes), `touch.swipe('left')` (true for one tick on a swipe in
  the named direction: left, right, up, down), `touch.drag` (true while one
  finger slides), `touch.pinch` (the two-finger spread over the spread at
  gesture start, one at rest), `touch.rotate` (two-finger twist in radians),
  `pointer.x` / `pointer.y` (the primary finger's last position, 0 to 1),
  `counter('name')` (a persistent counter's value, stepped by the counter
  actions below), `param('name')`.
- Comparisons: `>`, `<`, `>=`, `<=`, `==`, `!=` between a signal and a
  numeric or boolean literal.
- Boolean combinators: `&&`, `||`, `!`, grouped with parens.

That is the entire grammar. No arithmetic between two signals, no function
calls beyond the fixed signal readers above, no string concatenation, no
loops. A `when` expression nests at most 8 deep (parens or combinators);
deeper fails validation closed.

A `device.in_volume` signal reads a top-level `"volume"` region on the
manifest: `{"center": [x, y, z], "radius": r}` for a sphere or `{"center":
[x, y, z], "half": [hx, hy, hz]}` for an axis-aligned box, in world space. The
engine tests the submitted device pose against it on-device each tick and only
the inside/outside boolean reaches the lens; the pose itself never crosses the
ABI. With no world tracking or no volume declared, the signal reads false.

### 6.2 Actions

`param_ramp` (animate a parameter to a target over a duration, one of the
curve primitives in 6.3), `param_set` (immediate), `play_animation` (a
named glTF animation clip), `play_sound` (start a voice for the sound at
the bundle-relative path in `target`, decoded from `sounds/` and mixed into
the audio the host pulls out), `reset_timer` (name a timer signal back to
zero), the counter actions `increment_counter`, `reset_counter` and
`set_counter` (step a named counter that `counter('name')` reads and that
persists across ticks, so a no-code lens keeps a score or a step index with no
script; `set_counter` writes `to`), and `haptic` (buzz the device: `target`
names the style, one of light, medium, heavy, soft, rigid, success, warning,
failure, and `to` is a 0..1 intensity hint the host drains through
`goss_session_pull_haptic`). Reserved, accepted by the validator but not yet executed by the
runtime: `show` / `hide` (a node by id) and `swap_subgraph` (splice a
different set of this lens's own nodes in place of a named group -
edit-time, deferred to the next frame boundary so it never tears a
frame). A 1.0 runtime treats the reserved actions as no-ops; a lens
must not depend on them until a spec revision moves them out of this
paragraph.

### 6.3 Parameter animation

Curve primitives, chosen per `param_ramp`: `linear` (duration_ms, from
current value to target); the easing curves `ease_in_quad`,
`ease_out_quad`, `ease_in_out_quad`, `ease_in_out_cubic`, and
`ease_in_out_sine` (all duration_ms, shaping the same progress through
their curve so the ramp still lands exactly on target when its time is
up); and `spring` (stiffness, damping, target; a standard
critically-damped-tunable spring integrated at the fixed graph timestep,
not wall-clock, so it is frame-rate independent and deterministic across
platforms for the conformance harness). An unknown `curve` value fails
validation.

## 7. Assets

Every file in `shaders/` is a fragment shader for a full-screen pass over
the current frame. A lens does not author its own vertex stage. The
runtime supplies one fixed vertex contract, `lenses/shaders/varying.def.sc`,
shared by every lens shader pass: `a_position`/`a_texcoord0` in,
`v_texcoord0` out, the same shape as the engine's own preview passes. A lens
fragment shader is GLSL source written to that contract (bgfx's shader
dialect: `$input v_texcoord0`, `#include <bgfx_shader.sh>`).

A `shader.pass` node may also name a mask channel with a `mask` field. The
valid channel names are the same set every mask-keyed node draws from
(`tint.pass`, `smooth.pass`, `retouch.pass`, `matte.refine`, `outline.pass`,
`occluder.pass`).
Seven come from the segmentation model: `person`, `background`, `hair`,
`body_skin`, `face_skin`, `clothes`, `others`. The rest ride the face and hand
landmarks rather than a segmentation model: `head` and `hand` follow the tracked
head and hand, `lips`, `eyes`, `brows`, `iris`, and `teeth` are the face parts,
`contour` and `highlight` are clustered face regions (contour the cheekbone
hollows, nose sides, and jaw; highlight the cheekbone tops, brow bones, nose
bridge, cupid's bow, and chin), and `lash_line` is the upper lash-line band
each eye's upper lid arc rises into. Four more mark the retouch regions:
`under_eye` the band below each eye, `nasolabial` the smile-line fold, `sclera`
the eye-white inside the eye contour with the iris punched out, and `t_zone` the
forehead and nose bridge. A makeup or retouch lens keys those directly. One more
is derived on the GPU: `hair_matte` is the strand-level hair alpha a `matte.hair`
source refines from the coarse `hair` class against the camera luma, a soft
feathered edge a hair effect keys in place of the hard `hair` bit; with no
`matte.hair` source in the lens it serves the zero mask. Three name the scene
around the subject: `sky`, `ground`, and `building` come from a scene-parse
segmentation model. No such model is wired in yet, so a lens may key these today
and they serve the zero mask until one fills the scene slot. The
shader reads the channel through `SAMPLER2D(s_texMask, 2)` beside the frame's
own `s_texColor`. When a named channel has no live data (segmentation
disabled, a single-class model without it, or no face or hand tracked for a
landmark channel), the sampler serves the zero mask so the masked effect draws
nothing, the same degradation rule every capability follows. A `shader.pass`
that names no channel at all samples the all-foreground default instead, so a
shader that reads `s_texMask` without keying a channel still runs over the
whole frame. An unknown channel name fails validation.

Compilation happens at package time, not on the device: the engine's pinned
shader toolchain runs wherever a bundle is built or validated, producing
compiled bytecode for every platform profile a conforming runtime ships
(Metal / SPIR-V / ESSL), under the same resource limits the engine's own
shaders compile under: bounded compile time, no toolchain escape
hatches, compiler diagnostics surfaced as validation errors naming the
source file and line. A shader that
fails to compile fails the bundle's validation; there is no partial
lens. The runtime never compiles GLSL; it loads whichever precompiled
profile matches its own active graphics backend and hands the bytes
straight to its shader loader, the same call the engine's own built-in
passes already go through. This is deliberate, not a shortcut: nothing
else in the engine compiles a shader on the device, a mobile app has no
business carrying a C++ shader compiler toolchain just to run
user-authored effects, and a bundle that fails to compile is caught at
package time by the same validator a lens author already runs, not
discovered by an end user's device.

### 7.1 Material graphs

Instead of writing a fragment shader by hand, a `shader.pass` node may
carry a `material` block: a node graph the engine lowers to a fragment
shader and compiles at package time, exactly like an authored one. The
block is an `output` index and a `nodes` array. Each node is an object
with a `kind` and, as its kind needs, `inputs` (indices into the array),
`params` (up to four numbers), a `name` (a texture or uniform binding),
and a `type` (the value type of a `constant` or `uniform`: `float`,
`vec2`, `vec3`, `vec4`):

```json
{"type": "shader.pass", "inputs": {"frame": "camera"},
 "material": {"output": 4, "nodes": [
   {"kind": "uv"},
   {"kind": "texture", "name": "texColor"},
   {"kind": "sample", "inputs": [1, 0]},
   {"kind": "constant", "type": "vec4", "params": [1.0, 0.5, 0.2, 1.0]},
   {"kind": "multiply", "inputs": [2, 3]},
   {"kind": "output", "inputs": [4]}]}}
```

The graph is a typed DAG. Sources take no inputs: `uv` (the frame
coordinate), `time`, `constant`, `uniform` (host-set by name), and
`texture` (a sampler bound by name, `texColor` being the frame itself).
A `texture` named `generated` is a generative input: a diffusion or
`ml.infer` style node targeting the `shader.pass` binds its output to that
sampler, so a prompt-generated map feeds the material graph and the shader
samples it like any other texture. Without a generative node driving it the
sampler reads the frame, so the pass still runs.
`sample` reads a texture at a coordinate. Arithmetic (`add`, `subtract`,
`multiply`, `divide`, `power`, `min`, `max`, `mod`, `atan2`) and the vector
and scalar functions (`dot`, `distance`, `normalize`, `length`, `saturate`,
`abs`, `floor`, `fract`, `sin`, `cos`, `sqrt`, `clamp`, `step`, `smoothstep`,
`mix`) carry their operands' types through. `split` takes one channel out of
a vector, `combine3`/`combine4` build a vector from floats, and `lambert`
and `fresnel` shade from a normal, light, or view. `refract` bends an
incident vector about a normal by an index ratio (the sphere-warp math), and
`colormatrix` multiplies a `vec3` by three `vec3` rows to apply a general 3x3
colour transform: a channel swap, a sepia or saturation matrix, or an rgb
per-channel gain as its diagonal. `atan2` with a radius from `distance` gives
the polar remap a hue rotation or swirl needs. The single `output` node takes
a `vec4` and is the graph's root.

Validation rejects a graph with a cycle, a dangling input, a wrong
argument count, or a type mismatch, naming the offending node. A valid
graph lowers to the same GLSL contract as an authored shader and
compiles to every profile the same way, so a material a lens authors is
a real compiled shader on the device, not an interpreter. A vignette,
posterize, pixelate, or edge effect is a material graph with no dedicated
shader; see the `material-tint`, `material-vignette`, `material-posterize`,
`material-pixelate`, `material-edge`, `material-color-matrix` (a sepia
colour transform through `colormatrix`), and `material-sphere` (a sphere
refraction through `refract`, `distance`, and `atan2`) reference lenses.
Neighbour
sampling (an edge detector reads offset `uv` and compares) works too, so
a material graph is not limited to per-pixel math.

glTF/GLB assets bind through the engine's existing cgltf adapter: the same
allocator-bridged parse, the same refusal of external file references (a glTF
asset inside a bundle may not reference textures or buffers outside that
bundle). Textures and LUTs are plain image files decoded through the engine's
existing image decode path, bounded by the per-file size limit in 1.1.

## 8. Validation and the error model

Validation is total and ordered: bundle structure and size limits first,
then `manifest.json` schema and JSON depth, then `engine_compat`, then
capability names, then parameter/node/trigger cross-references (a node's
`inputs` or `params` naming an id or parameter that does not exist, a
trigger's action naming a node id that does not exist), then shader compile,
then asset decode. Validation stops at the first failing stage and reports
every error found *within* that stage (not just the first). A manifest
with three unknown node types reports all three, not one followed by a
second run to find the next. Every diagnostic names the exact JSON pointer
or file path and line it came from; "invalid manifest" alone is not a
conforming diagnostic.

A bundle that passes validation is guaranteed, by this document, to never
crash the engine, never allocate past its declared node/parameter/trigger
counts, and never execute anything the manifest did not declare. This is
the load-bearing security property: **lenses are untrusted content, and
untrusted content only ever flows through typed, bounded, validated data -
never through code.**

A lens can be authored on device from a text prompt. `goss_compile_prompt` reads
a short prompt and emits a GLF manifest composing the engine's asset-free
post-effect nodes: colour-grade words (warm, cool, bright, moody, mono) pick a
single grade, and look words add a blur, bloom, fog, edge outline, or sketch
stylize. The nodes emit in a fixed chain order whatever the word order, so the
same prompt always yields the same manifest, and a prompt naming no look still
grades gently rather than emitting an empty lens. The result is ordinary GLF a
caller inspects, saves, or hands straight to `goss_session_activate_lens`; the
bundle needs no assets, so the manifest is the whole lens.

## 9. Conformance

The reference set (`lenses/reference/`) carries at least one bundle
per node type and capability class the format defines: shader passes, the
beauty nodes and the masked makeup passes, `mesh.face`, glTF models and the
face, body, skeleton, and world anchors, physics bodies with joints and
jiggle, cloth, strand hair, CPU and GPU particles, material graphs, the
post-effect passes, and the sprite, text, video, script, and audio-playback
paths. The validator runs
against every one in CI (`lens-validate-reference`). A core subset also
runs end to end through the production ABI in the pixel-hash conformance
harness: shader-tint (no capabilities), beauty-baseline (face),
background-swap (segmentation), trigger-anim (none; a timer-driven glTF
animation), hair-recolor (segmentation; the hair mask channel), face-paint
(face; a `mesh.face` texture warp), and face-mask (face; a glTF model on
`"anchor": "face"`). world-anchor (world) is proven separately on the
deterministic replay camera track. The byo-ml path is proven in the same
harness: an `ml.infer` node runs a bundled TFLite segmenter and a bundled ONNX
net, each driving a lens parameter from the frame; an audio.infer node runs a
bounded model over the microphone window and drives a parameter, a doubling net
reading about twice a constant tone and near zero on silence; an audio.infer
caption binding greedy-CTC-decodes a logits tensor into text read back by node
id, a synthetic net's fixed logits decoding to a known word; an audio.infer
diarize binding clusters embeddings into speakers, a flat tone and an alternating
tone reading as two distinct speakers and the flat tone returning to its own;
an audio.infer translate binding runs a greedy autoregressive decoder over the
encoder memory, a synthetic transition decoder walking bos to a to b to eos and
yielding "ab"; an audio.infer dub binding synthesizes the decoded caption to
speech and plays it into the mixer, the pulled audio carrying a voice with
dubbing on and silent with it off; an author ONNX
segmenter's output reaches the subject mask channel; an `argmax` reduce reads a
classifier's predicted class into a parameter; a model output moves a sprite
through its placement parameters; a restyle net's output image draws through a
sprite; a super-resolution net whose output is a larger square than its input
draws through the style sprite at the enlarged side (16 from an 8 input);
a two-input ml.infer net conditions on a bundled reference, feeding both inputs
and drawing, where the same model with no reference is rejected at load;
a dehaze.pass lifts the atmospheric veil, strength 1 darkening a hazy frame
where strength 0 leaves it untouched; a relight.pass lights the frame
directionally, angle 0 brightening the right over the left where the uniform
strength-0 frame stays even; a glare.pass recovers a blown highlight, strength 1
pulling the bright region down toward the threshold where the normal region
holds; a vignette.pass applies a radial luma-gain, a positive strength lifting
the corners and a negative sinking them where the centre inside the radius holds;
a lowlight.pass lifts a dark noisy region far more than it moves a highlight and
cuts the shadow noise, where the strength-0 denoise-0 control is untouched;
an undistort.pass applies the submitted radial map, a positive k1 shrinking a
centred disk and a negative growing it, where no intrinsics leaves it inert;
a grade.pass naming a channel grades inside its mask in full and attenuates
outside it, where the unmasked grade changes that outside too;
an awb.pass estimates a gray-world balance from the frame thumb and neutralizes a
color cast, pulling the channel spread to under half where strength 0 is untouched;
a per-session inference budget caps the heavy workers, four ml.infer nets all
loading under a budget of eight but only two under a budget of two;
a stabilize.pass steadies a jittering camera, the settled inter-frame motion
falling to under half of the same lens with stabilization off;
a zoom.pass magnifies a centred region, a factor of 2 growing a centred disk
toward four times its area;
a dereflect.pass attenuates high-frequency detail in the bright regions far more
than the dark, the bright texture softening to under half while the dark holds;
a harmonize.pass matches the person's color distribution to the background, the
subject's red falling and blue rising toward the background while it holds;
an inpaint.pass fills a masked object from its surrounding boundary, the removed
region's red falling and blue rising toward the field while the field holds;
a temporal ml.infer net feeds the previous output frame into its second input,
a recurrent sum of the frame and its previous reading about twice a constant gray
where the same graph on a zero reference reads it once;
a diffusion loop over a bundled encoder, unet, and decoder restyles
the frame and draws it through a sprite; a diffusion lens with no encoder
generates from seeded noise and a text embedding, drawing the image through a
sprite; a diffusion lens keyed to the person channel composites its
generated image as the background behind the segmented subject; an img2img
diffusion lens with temporal coherence warps its previous frame by optical flow
and blends it into the restyle, holding the sprite steady across frames; and an
img2img diffusion lens masked to the face_skin channel in over mode composites
its restyle onto the face matte and holds the camera elsewhere; a masked-over
sprite mixes onto its region by mask_strength, the masked region moving from
camera at 0 to the full restyle at 1 while the region outside it never changes
with strength; a diffusion
node targeting a mesh.face node binds its generated image as the face mesh's
material texture; a splat.cloud node lifts the camera frame to a 3D point
set with a bundled model and draws it as a billboard cloud; a splat.cloud in mesh
mode reads the model's points as a grid and draws them as a connected 3D surface;
a diffusion node targeting a shader.pass binds its generated image to the material
graph's generated sampler; a selfie-source splat.cloud generates its avatar from
one submitted still through the avatar op and draws it off the per-frame camera;
a retarget avatar is reenacted by an injected source performance, an open source
jaw deforming the mesh where a closed one holds it at rest; a tracked avatar
renders in a toon art style and stays live, tracking an injected jaw while
differing from the un-stylized avatar; a colored splat.cloud reads a
six-channel model at stride six and draws each point in its own color;
and the prompt
compiler emits a GLF manifest on device that activates as a lens and renders.
The conformance harness runs today on the host (macOS): it renders each
covered lens through the production ABI and checks the output
byte-identical across two runs and against a tracked baseline
(`lenses/conformance-baseline.txt`), so a change that shifts a lens's
pixels shows up as a reviewed diff. Cross-platform value-stability for
anything resolution-independent (trigger fire timing, parameter curve
values at fixed timestamps) is the remaining work. The validator CLI (`lenses/validator`) is run against
every reference lens, and against a fuzz corpus of malformed manifests and
malformed shader inputs, in CI. A fuzz-found crash or leak is a spec
violation of section 8, filed and fixed before the next lens ships, not
triaged as a lens-author error.
