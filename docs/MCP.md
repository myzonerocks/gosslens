# The MCP server

Agents already have brains that understand images. What they lack is a way to
reach a live camera, a clip or a screen, and to act back into the frame. This
server is that reach: the engine as tools a model can call, over JSON-RPC on
stdin and stdout.

It is one static binary. No runtime to install, no SDK in between, and it speaks
the protocol itself, because the point of a frozen C ABI is that a thin thing
can sit on it.

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
| `read_perception` | What the engine sees, as one record: the frame, the faces, hands and bodies, what it says, and the engine's own state. |
| `read_text` | Every recognised region, with its quadrilateral, its confidence and a track id that survives a frame. |
| `annotate` | Draw back into the frame. Addressed by id, so moving one every frame leaks nothing, and carrying a lifetime. |
| `remember` | Put an embedding into the memory plane. The same id replaces rather than duplicating. |
| `search_memory` | The nearest remembered embeddings, fewer than asked on a smaller memory rather than padded. |
| `model_support` | Which operators a model needs that this build lacks, so a failure is a list rather than the word unsupported. |
| `engine_report` | The renderer backend, the pool high-water marks, frames drawn, and how far the engine has degraded. |

## What it does not do

Nothing here sends a frame anywhere. Every tool runs on this device, against the
same C ABI the Swift, Kotlin and TypeScript SDKs use, and a session's
[scope](API.md) governs what it will answer: a read out of scope is dropped from
the record, and a verb out of scope is refused.

A tool called before a session is attached says so rather than returning an empty
answer a model would read as a fact.
