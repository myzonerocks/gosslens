# The lens format

A gosslens lens is a single JSON document, the GLF (Goss Lens Format). It
declares what a lens needs, what it draws, and what makes it move, and nothing
else: no code ships in a lens, only data the engine interprets. The same
document runs byte-identically on every platform the engine targets, because the
runtime that reads it is the same Zig core everywhere.

This file is the format's public contract. The reference parser is
[core/lens/manifest.zig](../core/lens/manifest.zig); where this document and the
parser disagree, the parser is the format and this document is the bug. The
format is versioned so a lens authored today keeps working, and it is meant to be
forked: nothing here depends on a hosted service.

## Shape

A lens is one JSON object with these top-level fields.

| Field | Required | Meaning |
|---|---|---|
| `glf` | yes | Format version, `"1.x"`. This runtime reads the `1` line; a newer minor degrades rather than failing. |
| `id` | yes | Stable reverse-DNS identifier, e.g. `com.example.mylens`. |
| `version` | yes | The lens's own semantic version. |
| `display_name` | yes | Human-facing name. |
| `engine_compat` | no | An engine version range, e.g. `">=0.5"`, refused if the running engine falls outside it. |
| `capabilities` | no | The inputs the lens is allowed to touch (see below). A lens reaches nothing it did not ask for. |
| `parameters` | no | Named, typed, bounded values the lens exposes for the host and its own triggers to drive. |
| `nodes` | no | The render and effect graph. |
| `triggers` | no | What reads signals and drives parameters or actions over time. |
| `volume`, `gestures`, `hdr`, `light` | no | Optional scene declarations: an interaction volume, custom hand gestures, a request for the high-dynamic-range compositing chain, and a scene light. |

## Capabilities

`capabilities` is the lens's declared surface: `face`, `hands`, `segmentation`,
`world`, `audio_level`, and the others the parser enumerates. It is an opt-in
list, not a hint. A lens that does not declare `face` never sees a face landmark,
so a reviewer reads one array to know what a lens can observe, and the engine
enforces it rather than trusting the lens.

## Parameters

Each parameter has a `name`, a `type`, a `default`, and, for the numeric types, a
`min` and `max` the engine clamps into. The types are the small closed set the
parser accepts (`float`, `int`, `color`, and the rest). A parameter is the only
mutable state a lens carries: the host sets it, a trigger ramps it, a script
writes it, and the renderer reads it. Nothing else about a running lens changes.

## Nodes

`nodes` is the effect graph. Every node has a `type` and an `id`, and each type
adds its own fields. The types group into a few families:

- **Content**: a glTF model (`model.gltf`), a 2D sprite (`sprite.2d`), 2D text
  (`text.2d`), a video texture (`video.texture`) - the things a lens draws.
- **Image passes**: colour, blur, bloom, grade, relight, stylize, inpaint, and
  the rest of the `*.pass` family - full-frame effects composited in order.
- **Model slots**: `ml.infer` and the ONNX/TFLite variants - a bring-your-own
  model whose output binds to a parameter, a mask, a stylized image, or the
  scene depth. The engine runs the model; the lens names the file and the
  binding, and any model that fits the slot plugs in.
- **Logic**: `logic.graph` and the scripting node - deterministic per-tick
  computation with no ambient authority.

The authoritative list of node types and their fields is the parser; this
document names the families rather than pinning a count that grows.

## Triggers

A trigger is a `when` and an `action`. The `when` is a signal expression over the
capabilities the lens declared - a face blendshape crossing a threshold, a hand
gesture, a beat, a tap, a geofence, the lens clock. The `action` is one of the
closed set the parser accepts: ramp a parameter, set a parameter, play a sound,
activate content, and so on. Triggers are how a lens moves without carrying code:
the engine evaluates the expression each frame and applies the action.

## Coordinates and determinism

Screen-space values are normalized `0..1` with the origin at the top-left. World
content is placed in the submitted world pose. Given the same lens, the same
inputs, and the same frame timings, the engine produces the same bytes out on
every platform; the conformance harness pins this for the generative and tracking
paths, and any drift is a conformance failure, not a tolerance.

## Trust boundary

A lens is untrusted input. The parser fails closed: a malformed document yields a
manifest or typed diagnostics, never a crash, an out-of-bounds read, or a native
stack overflow. That property is fuzzed - a valid manifest is mutated
deterministically thousands of times and re-parsed under a leak-checking
allocator, and the run is part of the same conformance suite - so forking the
format does not mean forking a security review from scratch.

## Authoring

A lens is plain JSON, so it is writable by hand, by a tool, or by the engine's own
`goss_compile_prompt`, which turns a text prompt into a GLF document on device
with no assets. Whatever writes it, the result is the same inspectable document
this file describes, and it runs through the one ABI the SDKs are built on
([API.md](API.md)).
