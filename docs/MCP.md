# The MCP server

An MCP server over the engine's C ABI. It exposes the session as tools a model
can call: open a source, read what the engine sees, read what the frame says,
search the memory plane, and draw back into the frame.

One static binary speaking JSON-RPC on stdin and stdout. It implements the
protocol directly rather than through an SDK, so there is no runtime to install
and nothing between the tools and the ABI.

```sh
zig build            # builds zig-out/bin/gosslens-mcp
zig build mcp        # runs it on stdio
```

Point a client at the binary:

```json
{
  "mcpServers": {
    "gosslens": { "command": "/path/to/zig-out/bin/gosslens-mcp" }
  }
}
```

## The tools

| tool | what it is for |
| --- | --- |
| `open_clip` | Opens a video file as a source. The graph cannot tell a clip from a camera, so everything below works on it. |
| `open_screen` | Opens a display or a window as a source. Where permission has not been granted it says no surface is available rather than failing. |
| `screen_point` | Where a normalized point lands on the captured surface: logical points, backing pixels, and the desktop. |
| `read_perception` | What the engine sees, as one record: the frame, the faces, hands and bodies, what it says, and the engine's own state. |
| `read_text` | Every recognised region, with its quadrilateral, its confidence and a track id that survives a frame. |
| `annotate` | Draw back into the frame. Addressed by id, so moving one every frame leaks nothing, and carrying a lifetime. |
| `remember` | Put an embedding into the memory plane. The same id replaces rather than duplicating. |
| `search_memory` | The nearest remembered embeddings, fewer than asked on a smaller memory rather than padded. |
| `open_screen` | Opens a shared screen or window as a source, and answers its logical size, scale and desktop origin. |
| `screen_point` | Where a point in the frame lands: in the surface's logical coordinates, in its pixels, and on the desktop. |
| `model_support` | Which operators a model needs that this build lacks, so a failure is a list rather than the word unsupported. |
| `engine_report` | The renderer backend, the pool high-water marks, frames drawn, and how far the engine has degraded. |

## What it does not do

Nothing here sends a frame anywhere. Every tool runs on this device, against the
same C ABI the Swift, Kotlin and TypeScript SDKs use, and a session's
[scope](API.md) governs what it will answer: a read out of scope is dropped from
the record, and a verb out of scope is refused.

The spatial questions are not tools here, deliberately. They answer over the
planes, anchors and mesh a host submits, and this server stands up its own
session that no host feeds, so every one of them would answer "nothing submitted"
forever. They reach a model through an SDK inside an app that has a world.

The engine and its session are made on the first call that needs them, so a
client that only lists tools brings up no renderer. A tool whose precondition is
missing says which one it is, rather than returning an empty answer a model would
read as a fact: no surface has been granted, no frame has been submitted, the
text rail is not enabled on this session.
