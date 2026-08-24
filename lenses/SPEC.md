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
first result not yet landed) samples the zero mask - the masked effect
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
tracked body the node draws nothing.
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
(0 dead, 1 bouncy) set its surface material, and
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

A `"blur.pass"` node is a standalone post-effect: it softens whatever frame
reaches it with the engine's built-in separable box blur and passes the
result down the chain, the same primitive `beauty.face`'s smooth step uses,
here exposed as its own node so a lens can blur the full frame without a
beauty filter. It reads `shaders/*.glsl` nothing and ships no asset - the
program is kit-authored and fixed - so it is always ready and never
degrades. Place it anywhere in the chain; it blurs its input and hands the
softened frame to the next node.

A `"grade.pass"` node is a parametric color grade post-effect. It carries a
`"grade": {"exposure", "contrast", "saturation", "temperature"}` block and
shifts whatever frame reaches it - exposure in stops, contrast and
saturation as multipliers around 1, temperature a warm/cool push - then
hands the graded frame down the chain. Every field is optional and defaults
to the identity, so a `grade.pass` with an empty block leaves the frame
untouched. Like `blur.pass` it ships no asset and is always ready; it lets a
lens warm, cool, brighten or push contrast without authoring a LUT.

A `"bloom.pass"` node is a glow post-effect. It carries a `"bloom":
{"threshold", "intensity"}` block: it extracts the frame's highlights - what
sits above `threshold` in luma - blurs them, and adds that blurred glow back
over the frame scaled by `intensity`, so bright areas bleed a soft halo.
Both fields are optional with engine defaults. Like `blur.pass` and
`grade.pass` it ships no asset and is always ready.

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

An `"outline.pass"` node is a depth-edge outline post-effect. It carries an
`"outline": {"color", "threshold"}` block: where the submitted depth jumps
between neighboring pixels by more than `threshold` it draws `color` (three
0..1 numbers) over the frame, so silhouettes and creases get a toon outline
while flat depth stays untouched. Like `dof.pass` and `fog.pass` it reads the
host's depth, holds the frame through with none submitted, ships no asset,
and defaults its fields.

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
each frame, so a param_ramp fades the sprite or a beat trigger pulses it. A
`"frames"` count above one makes the sprite animated: it loads
`assets/<id>_0.png` through `assets/<id>_(frames-1).png` and cycles them at
`"fps"` off the lens clock. Shipping the image as an animated GIF at
`assets/<id>.gif` instead plays the clip as a video texture: the engine
decodes its frames and cycles them at the clip's own frame timing, so a
sticker animates without a param or a frame count. Until its image decodes
(all frames, for an animated sprite) the node holds the frame through, never
blocking the chain.

A `"text.2d"` node draws a line of text over the frame. It carries a `"text":
{"content", "x", "y", "w", "h", "opacity", "color"}` block: the string to
draw, the same normalized rect and opacity a sprite takes, and an rgb color
(three 0..1 numbers) for the glyphs. The engine rasterizes the string with a
built-in font, so a text node ships no asset, and composites it into the rect
like a sprite; it takes the same `"opacity_param"` for a parameter-driven
fade. A newline in the `content` starts a new line, so a multi-line caption
fits the rect as several rows. The font covers space, digits, upper- and
lowercase letters, and common punctuation; any other character draws blank.

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
surface is the six live signals (`face_present`, `hands_present`,
`audio_level`, `audio_beat`, `world_tracking_state`, `tap`) plus every ARKit
blendshape by name (`lens.signals.jawOpen`, `mouthSmileLeft`, and the rest),
so a script reacts to an expression the way a trigger reads `jawOpen.blendshape`. Whatever it
writes to a parameter flows into that tick like any other parameter change.
The runtime is sandboxed and deterministic: no filesystem, network, wall
clock, or randomness is in scope (`Date` and `Math.random` are removed), and
each tick is bounded by a fuel limit, so a script can neither reach outside
the lens nor hang the frame. The same inputs always produce the same writes,
which is what lets a scripted lens be conformance bit-stable.

The set of known `type` values is closed and versioned with the *engine*, not
the format - GLF 1.0 does not let a lens introduce a new node type, only
compose the runtime's built-in ones (capture input, beauty filters, shader
passes reading `shaders/*.glsl`, glTF model draws, LUT passes, compositing,
the draw board, the layout composite, the 2D sprite, the 2D text, and `mesh.face` - the canonical face mesh warped by the tracked landmarks,
textured by `assets/<id>.png` in canonical UV space with v measured from
the bottom; without a tracked face the node draws nothing, the standard
capability degradation).
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
  `param('name')`.
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
zero). Reserved, accepted by the validator but not yet executed by the
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

A `shader.pass` node may also name a segmentation mask channel with a
`mask` field: `person`, `background`, `hair`, `body_skin`, `face_skin`,
`clothes`, or `others`. The shader then reads it through
`SAMPLER2D(s_texMask, 2)` beside the frame's own `s_texColor`. When the
running session cannot provide the channel (segmentation disabled, or a
single-class model without it), the sampler serves the all-foreground
default, the same degradation rule every capability follows. An unknown
channel name fails validation.

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
`sample` reads a texture at a coordinate. Arithmetic (`add`, `subtract`,
`multiply`, `divide`, `power`, `min`, `max`, `mod`) and the vector and
scalar functions (`dot`, `normalize`, `length`, `saturate`, `abs`,
`floor`, `fract`, `sin`, `cos`, `clamp`, `step`, `smoothstep`, `mix`)
carry their operands' types through. `split` takes one channel out of a
vector, `combine3`/`combine4` build a vector from floats, and `lambert`
and `fresnel` shade from a normal, light, or view. The single `output`
node takes a `vec4` and is the graph's root.

Validation rejects a graph with a cycle, a dangling input, a wrong
argument count, or a type mismatch, naming the offending node. A valid
graph lowers to the same GLSL contract as an authored shader and
compiles to every profile the same way, so a material a lens authors is
a real compiled shader on the device, not an interpreter. A vignette,
posterize, pixelate, or edge effect is a material graph with no dedicated
shader; see the `material-tint`, `material-vignette`, `material-posterize`,
`material-pixelate`, and `material-edge` reference lenses. Neighbour
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

## 9. Conformance

A lens exercises exactly one distinct capability class per the reference
set (`lenses/reference/`). Shipped today: shader-tint (no capabilities; a
plain shader pass), hair-recolor (capabilities: segmentation; a shader
pass reading the hair mask channel), face-paint (capabilities: face; a
mesh.face node warping a texture over the tracked face), beauty-baseline (capabilities: face; the beauty node
type), background-swap (capabilities: segmentation), trigger-anim
(capabilities: none required; a timer-driven trigger playing a glTF
animation clip, proving 6.2/6.3 without needing a live face), face-mask
(capabilities: face; a glTF model pinned to the head through
`"anchor": "face"`), and world-anchor (capabilities: world; a glTF
model pinned to the tracked world, proven on the deterministic replay
camera track). The reference set is complete. Each reference lens runs through the conformance
harness on all three platforms and is asserted bit-stable per platform
(pixel output) and value-stable across platforms for anything
resolution-independent (trigger fire timing, parameter curve values at
fixed timestamps). The validator CLI (`lenses/validator`) is run against
every reference lens, and against a fuzz corpus of malformed manifests and
malformed shader inputs, in CI. A fuzz-found crash or leak is a spec
violation of section 8, filed and fixed before the next lens ships, not
triaged as a lens-author error.
