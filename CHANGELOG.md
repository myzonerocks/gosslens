# Changelog

Every change that reaches a user lands under **Unreleased** in the pull request that makes it.
A release moves that section under its tag with the date, and the release notes are that section.

## Unreleased

- The engine is real-time visual plumbing for agents, and the documents say so: one versioned
  record of everything it sees, the same record as JSON, a bounded event stream, budgeted frame
  egress, and annotations an agent draws back into the frame.

- An MCP server ships in the repository: one static binary speaking JSON-RPC on stdio over the
  same C ABI every SDK uses, so the session is tools a model can call with no runtime to install.
  Ten tools answer from the engine, including opening a shared screen and turning a point in the
  frame into a point on the desktop; the engine and its session come up on the first call that
  needs one, and a tool whose precondition is missing names that one precondition.

- Media is a contract the core owns. A clip is a source the graph cannot tell from a camera, with
  seek, presentation timestamps and audio; the portable codecs are pinned with their licences; and
  colour metadata drives the conversion, from the matrix coefficients rather than the primaries.

- Recording pauses and resumes without leaving a gap, and an interruption the host declares is
  accounted for rather than counted as drift.

- The ONNX engine runs modern vision: around ninety operators added, including attention's einsum,
  the reductions, the gather and scatter families, the detector's TopK and non-max suppression, the
  int8 path with per-channel scales, and If, Loop and Scan under a hard depth and iteration bound.
  Nine published models run through it, fetched by digest and never committed.

- Inference allocates nothing after load. Constants fold, dead nodes go, batch normalization folds
  into the convolution before it, and one measuring run at load sizes the single buffer every later
  frame reuses.

- `goss_ml_op_support` names exactly which operators a model needs and this build lacks, so a
  failure is a precise list rather than the word unsupported.

- What the frame says is a first-class result: a detector and a recogniser on the engine's own
  model rail, oriented quadrilaterals, per-character confidence, reading order, and a track id
  that survives a frame. A region whose pixels have not changed keeps its reading.

- Screens are a source. A display or a window arrives through ScreenCaptureKit, MediaProjection or
  `getDisplayMedia`, carrying the scale factor and desktop origin that put a coordinate an agent
  sent back onto a real pixel.

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

- Spatial queries answer in metres with their uncertainty attached, plane semantics are named
  channels rather than an opaque number, and anchors survive a session with their purpose and
  label but not with a confidence nothing has re-earned.

- Scope: a host narrows what a session answers with two words, the sections a caller may read and
  the verbs it may act with. A read out of scope is dropped from the record; a verb out of scope is
  refused.

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
