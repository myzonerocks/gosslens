# The perception format

What the engine saw, as bytes a consumer can read without linking the engine.
One versioned record per frame, an event stream beside it, and a scope that says
what either will carry. No code ships in a record, only data.

This file is the format's public contract. The reference writer and reader are
[core/perception/snapshot.zig](../core/perception/snapshot.zig) and the declared
layout is [core/perception/schema.zig](../core/perception/schema.zig); where this
document and those disagree, they are the format and this document is the bug.
A baseline gate (`zig build schema-check`) holds the layout still, so a field
cannot be reordered or dropped inside a major without a diff somebody reads.

## The record

Little-endian throughout. A record is a header followed by sections, each a tag,
a version, a length and a payload.

| Field | Type | Meaning |
|---|---|---|
| magic | `[4]u8` | `GSP1`, so a buffer that is not a record is refused rather than half-read. |
| schema | `u16` | The format version. This runtime writes `1`. |
| reserved | `u16` | Zero. |
| total | `u32` | The whole record in bytes, so a reader knows where it ends without walking it. |
| snapshot_us | `i64` | When the engine took this, in the same clock the frames carry. |

The header is 20 bytes. Then, per section:

| Field | Type | Meaning |
|---|---|---|
| tag | `u16` | Which section (below). |
| version | `u16` | That section's own version, which moves without the schema's. |
| length | `u32` | Payload bytes, so an unknown tag is stepped over rather than guessed at. |
| payload | `[length]u8` | The section's own fields. |

**A reader must step over a tag it does not know.** That is the whole
compatibility rule: an older consumer reads a newer record, skipping what it
cannot name, and a newer consumer reads an older record with sections absent. A
consumer that fails on an unknown tag is a consumer that breaks on the next
release.

## The sections

| Tag | Name | Payload |
|---|---|---|
| 1 | `frame` | `u32` width, height, pixel_format, color_standard, color_range, flags; `i64` timestamp_us; `u64` frames_submitted. |
| 2 | `faces` | `u32` count, then per face: `f32` presence, `u32` landmarks declared, `u32` landmarks carried, then three `f32` per landmark. |
| 3 | `hands` | `u32` count, then per hand: `f32` handedness, `u32` gesture, `f32` gesture score. |
| 4 | `bodies` | `u32` count, then per body the same shape as a face. |
| 5 | `segmentation` | `u32` whether a mask is live. |
| 6 | `world` | `u32` tracking state, plane count, anchor count. |
| 7 | `depth` | `u32` whether a depth map is live. |
| 8 | `scene` | `u32` label count, then per label its id and score. |
| 9 | `text` | `u32` count, then per reading: eight `f32` of quadrilateral in reading order, `f32` confidence, `u32` origin, script, direction, track_id, line, paragraph, text_len, then `text_len` bytes of UTF-8. |
| 10 | `audio` | `f32` level, `u32` beat, `u32` engine_fed. |
| 11 | `lens` | `u32` whether a lens is active, node count. |
| 12 | `engine` | `u32` degrade_level, degrade_transitions; `u64` frames_rendered; `u32` script_faults. |
| 13 | `embedding` | `u32` dim, `u32` source, then `dim` `f32`. |

An eight-byte field is aligned to eight inside a payload. A section whose count
is zero still appears, because absent and empty are different facts: no face
found is not the same as faces never looked for.

## Selecting sections

A caller passes a bitmask in the section order above, bit zero being `frame`. A
snapshot is read every frame by a consumer that usually wants two sections, and
writing all thirteen to be ignored is the cost selection avoids.

## Scope

A host narrows what a session will answer, once, with two words: the sections a
caller may read and the verbs it may act with. A read out of scope is **dropped
from the record**, not refused, so a consumer asking for everything receives what
it is entitled to rather than an error it cannot act on. A verb out of scope is
refused outright.

A section this build does not know has no bit, so a newer engine's section cannot
be granted by an older engine that has never heard of it.

## Events

An event is a kind, a timestamp and a payload, on a bounded ring. When the ring
is full the **oldest** is dropped and the count of drops is reported and cleared
on read, so a consumer learns it missed something rather than silently seeing a
gap. A drop is itself reportable, which is the only honest way to say "there was
more than this".

## Determinism

The same input stream produces the same records, byte for byte, on the same
target. That is a gate, not an aspiration: `harness/determinism.zig` compares two
runs and names the first frame and byte at which they parted, and a run that
stopped early is reported as its own kind of failure rather than as a
disagreement.

## Forking this

Nothing here depends on a hosted service, and the record is readable with a
little-endian reader and this table. The JSON projection
([core/perception/json.zig](../core/perception/json.zig)) is generated from the
binary record rather than written separately, so the two cannot drift; if you
implement one of them, implement it from the record.
