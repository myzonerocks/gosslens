# Changelog

Every change that reaches a user lands under **Unreleased** in the pull request that makes it.
A release moves that section under its tag with the date, and the release notes are that section.

## Unreleased

## v0.13.0 (2026-09-13)

The engine reaches an agent rail: a camera, a clip or a screen in, one versioned record of what is
in it out, and whatever an agent draws composited back, over a frozen C ABI that every SDK and an
MCP server all speak. Everything below is new since the last release.

- The engine is real-time visual plumbing for agents, and the documents say so: one versioned
  record of everything it sees, the same record as JSON, a bounded event stream, budgeted frame
  egress, and annotations an agent draws back into the frame.

- An MCP server ships in the repository: one static binary speaking JSON-RPC on stdio over the
  same C ABI every SDK uses, so the session is tools a model can call with no runtime to install.
  The tools all answer from the engine, including opening a shared screen, turning a point in the
  frame into a point on the desktop, and the spatial questions: where the floor is, whether a cup
  fits on a surface, how far apart two points are with the error bar, a path across scanned
  geometry, and two devices agreeing on one room; the engine and its session come up on the first
  call that needs one, and a tool whose precondition is missing names that one precondition.

- Media is a contract the core owns. A clip is a source the graph cannot tell from a camera, with
  seek, presentation timestamps and audio; the portable codecs are pinned with their licences; and
  colour metadata drives the conversion, from the matrix coefficients rather than the primaries.

- Recording pauses and resumes without leaving a gap, and an interruption the host declares is
  accounted for rather than counted as drift.

- The ONNX engine runs modern vision: around ninety operators added, including attention's einsum,
  the reductions, the gather and scatter families, the detector's TopK and non-max suppression, the
  int8 path with per-channel scales, and If, Loop and Scan under a hard depth and iteration bound.
  Published models are held to it, fetched by digest and never committed. Those inside a lens
  bundle's asset cap run a frame through the graph, a classifier and a detector and a depth net
  among them; those past it are held to loading, planning and naming no operator this build
  lacks.

- Inference allocates nothing after load. Constants fold, dead nodes go, batch normalization folds
  into the convolution before it, and one measuring run at load sizes the single buffer every later
  frame reuses.

- `goss_ml_op_support` names exactly which operators a model needs and this build lacks, so a
  failure is a precise list rather than the word unsupported.

- What the frame says is a first-class result: a detector and a recogniser on the engine's own
  model rail, oriented quadrilaterals, per-character confidence, reading order, and a track id
  that survives a frame. A region whose pixels have not changed keeps its reading.

- What is in frame reaches an agent. A detector's own output tensors are read as
  detections through a `detect` block on the ml node: labelled boxes in the normalized
  frame, in the record and on the event ring as one arrives, leaves or changes what it
  is. The input range is part of that contract: an export wanting zero to two hundred and
  fifty five, fed zero to one, runs and finds nothing, which reads as a model that works,
  so `input_range` takes `byte` beside `unit` and `symmetric`.

- Every event kind the header declares now reaches a host. A subscription to a plane
  arriving, a hand appearing, the device warming, a trigger firing or a frame dropping
  used to wait for something the engine never sent, and a gate refuses a kind nothing
  emits.

- The model rail's frame allocator is constant time. Its free list scanned every block on every
  allocation and rescanned the whole array on every free, so one trip through a detector's
  five-thousand-node post-processing loop paid for all the allocations before it. Blocks are
  linked in address order now, free ones threaded onto a list per size class, and each allocation
  carries its own block index: 27 per cent faster on a quarter less memory for the same inference.
  A frame that outgrows its plan spills into the arena and sizes the plan for the next one, rather
  than being thrown away and run again.

- A model rail says what it costs. `goss_session_read_report` carries the bytes every model reuses
  each frame and how often one had to grow, summed over the session and snapshotted where the
  outputs are, so a host can tell a plan that has settled from a number that happens to be true
  this frame. One growth is the design; two is a rail that is not settling.

- The ABI version moves on a struct change, not only on a new op. `GOSS_ABI_MINOR` derives from
  the op list and every field of every struct that crosses the boundary, and the update is refused
  if the surface moved while the version stood still. A caller that sizes a struct by the version
  it built against can no longer be handed a wider one.

- Screens are a source on every host the engine runs on. A display or a window arrives through
  ScreenCaptureKit, MediaProjection, `getDisplayMedia`, Xlib, the Wayland portal with its PipeWire
  stream, or GDI, each carrying the scale factor and desktop origin that put a coordinate an agent
  sent back onto a real pixel. The desktop libraries load at run time, so a build needs no X
  headers, no PipeWire headers and no Windows SDK, and a host missing one answers zero surfaces,
  which is the same answer as permission not granted.

- The memory plane remembers and finds again: a navigable index over embeddings with the exact
  search beside it as the oracle its recall is measured against, a bounded event log, keyframe
  selection that measures novelty against what is already remembered, and a versioned file that
  answers the same queries after a round trip.

- The memory seals under a host key: an index of embeddings is a record of what a camera saw, so a
  file lifted off the device is bytes rather than a diary, and a wrong key, a changed byte or a
  relabelled file each fail rather than producing plausible plaintext.

- Two devices agree on a point by exchanging landmark ids and positions in each sender's own frame,
  never a pose, because a pose is meaningless in another origin. The alignment reports the fit it
  achieved and refuses fewer than three matches.

- `goss_perception_select_all` answers which snapshot sections this build writes. Every SDK had been
  defaulting to a mask typed by hand, which excluded the embedding section from the day it landed.

- Two devices in one room agree on where a point is by exchanging landmarks and never
  a pose, and the transform between their origins is the full rigid one: the rotation
  comes from the cross-covariance of the matched sets, so devices facing different ways
  agree and a pose arrives turned as well as moved, with the fit it achieved attached.

- A walkable route across the submitted world mesh, so an agent walks content over real
  scanned ground rather than through it. Refused when no mesh is submitted or no route exists,
  because a caller can act on "not here" and cannot act on an empty list.

- Spatial state is reachable: the spatial ops answer over the planes and anchors a host already submits,
  so an agent asks which surface is the floor, where a footprint fits and how much of that surface
  it leaves, what a distance is with the uncertainty its inputs carried, and what the transform
  between two devices' origins is. Anchors survive a session with their purpose and label, and
  never with a confidence nothing has re-earned.

- Scope is a boundary rather than advice. A verb per class of action covers the acting surface, each checked at
  every op it gates and each one nameable, so a refusal reads as a sentence instead of a bitmask. A
  verb out of scope answers `out_of_scope`, which a host can grant, never `unsupported`, which it
  cannot. A session's scope only ever narrows: anything running inside it can ask, so widening means
  a new session. A read out of scope is still dropped from the record rather than failing the call.

- The model rail no longer needs vendored C++ to answer. A build without the TFLite tree runs every
  ONNX model through the pure-Zig engine and only degrades a `.tflite` node, on the host, on Android
  and on iOS, which is what the web build already did.

- A PNG decodes through the engine, for a caller holding an encoded image and no decoder of its own.

- The perception format is written down (`docs/PERCEPTION-FORMAT.md`) so a consumer implements
  against it without reading the engine, and a baseline gate holds the layout still.

- A tensor holding nothing flows through every operator instead of overrunning it. A zero extent
  was read as one in ninety-six places, so a detector that selected nothing read off the end of an
  empty buffer, and a graph with control flow lost the values its body captured: the optimizer saw
  them as unused and deleted them. Both are gone, and every node now checks the tensors it wrote
  whichever path it took.

- A module the build swaps per target now answers every name the tree asks of the real one, held
  there by a gate rather than by a compile on the one target that happened to be built.

- A changelog, covering every release from the first, and the release notes are the section it
  cuts, so a reader of the release and a reader of `main` see the same words. The gate refuses a
  change that reaches a user without a line under Unreleased.

## v0.12.0-alpha.3 (2026-09-09)

- A named source takes a page-made texture, so the web ingress is zero-copy like the others.
- The web microphone input takes the page's own stream rather than opening a second one.

## v0.12.0-alpha.2 (2026-09-09)

- A shipped slice is ReleaseFast unless a mode is named.
- A pre-release publishes as one.

## v0.12.0-alpha.1 (2026-09-09)

- A shipped library carries no debug tables.
- The Swift package serves a checkout and a release alike, as framework slices with their link
  needs, so two binary frameworks no longer collide over one include folder.
- The C each adapter sees is a build step rather than an `@cImport`.
- `build.zig` reads whichever Zig it runs under.
- Serious thermal pressure leaves a cheap frame alone.
- The chain report reaches every SDK.

## v0.11.1 (2026-09-02)

- A whole-codebase leak and hostile-input audit, and every finding closed.

## v0.11.0 (2026-09-02)

- The host-facing ML rail: a host stages a model in memory and reads tensors back, rather than
  every model arriving inside a lens bundle.
- The Swift XCFramework publishes from the root manifest.

## v0.10.1 (2026-09-02)

- Beauty fails closed without a live GL context instead of drawing nothing and saying nothing.
- The pre-push hook runs the required gates, so a push cannot outrun them.

## v0.10.0 (2026-09-01)

- Conformance closure: the CI lanes, media and SDK completeness, and the doc-truth pass that
  makes every claim in the documents something the harness checks.

## v0.9.0 (2026-09-01)

- Connected AR, recognition, media, the world mesh, and the SDK release pipeline.
- Microphone echo cancellation in the audio suite.

## v0.8.0 (2026-08-30)

- Every audited engine deferral closed.

## v0.7.1 (2026-08-30)

- Guided-capture reconstruction draws live through `splat.cloud`.

## v0.7.0 (2026-08-30)

- Gaussian-splat and 3D-photo capture, render and depth.

## v0.6.0 (2026-08-30)

- The ML runtime and on-device generative passes.
- Avatars, and neural enhancement.
- A Windows host builds and gates on a Windows checkout.

## v0.5.0 (2026-08-28)

- Scripting and interactivity, and the rest of the appearance set.

## v0.4.0 (2026-08-26)

- Segmentation mattes, makeup and reshape.
- Simulation depth and the last post-processing primitives.
- The public documents grounded and corrected against the code.

## v0.3.0 (2026-08-23)

- Rendering and material depth.
- Body tracking breadth, and depth occlusion.

## v0.2.0 (2026-08-23)

- Multi-person bodies: a submit path, body-anchored models that fan out across every tracked
  body, and a skeleton anchor that tiles a rig over one.
- Analytic two-bone inverse kinematics.
- Jump, wave and dance as trigger signals.

## v0.1.0 (2026-08-20)

- The repository itself: the pinned toolchain, the source-tracked gate and the CI lanes.
- Core math, the frame graph, and the C ABI with the diff gate that freezes it.
