//! The agent rail in a page: what the engine sees as a record, what the frame
//! says, the memory plane, a screen, and an annotation drawn back into the frame.
//! The same five things the MCP server hands a model, driven by hand here so a
//! reader can watch each one answer on their own camera.

import { shareScreen, type GossAnnotation, type GossScreenShare, type GossSession } from "../src/index.ts";

/// How wide an embedding the demo remembers. The face carries 478 landmarks;
/// their first coordinates are a stable enough signature for a demo, and a short
/// vector keeps the memory plane's own cost visible.
const EMBEDDING_DIM = 96;

export interface AgentRailHost {
  session: GossSession;
  /// The newest face landmarks, or null with no face. The rail reads rather than
  /// holds them, so nothing here goes stale behind the render loop.
  landmarks: () => Float32Array | null;
}

/// Turns the newest landmarks into an embedding of a fixed width, centred and
/// scaled so the same face at a different distance lands in the same place.
function embeddingFrom(landmarks: Float32Array): Float32Array | null {
  const count = Math.min(EMBEDDING_DIM / 2, landmarks.length / 3);
  if (count < 8) return null;
  let cx = 0;
  let cy = 0;
  for (let i = 0; i < count; i += 1) {
    cx += landmarks[i * 3]!;
    cy += landmarks[i * 3 + 1]!;
  }
  cx /= count;
  cy /= count;
  let scale = 0;
  for (let i = 0; i < count; i += 1) {
    scale = Math.max(scale, Math.abs(landmarks[i * 3]! - cx), Math.abs(landmarks[i * 3 + 1]! - cy));
  }
  if (scale <= 0) return null;
  const out = new Float32Array(EMBEDDING_DIM);
  for (let i = 0; i < count; i += 1) {
    out[i * 2] = (landmarks[i * 3]! - cx) / scale;
    out[i * 2 + 1] = (landmarks[i * 3 + 1]! - cy) / scale;
  }
  return out;
}

export function attachAgentRail(host: AgentRailHost): void {
  const panel = document.getElementById("agent-rail");
  const output = document.getElementById("agent-out");
  if (!panel || !output) return;

  const say = (text: string) => {
    output.textContent = text;
  };

  let memoryDim = 0;
  let nextId = 1;
  let share: GossScreenShare | null = null;

  const button = (id: string, run: () => void | Promise<void>) => {
    document.getElementById(id)?.addEventListener("click", () => {
      try {
        const maybe = run();
        if (maybe) void maybe.catch((err: unknown) => say(String(err)));
      } catch (err) {
        say(String(err));
      }
    });
  };

  button("agent-read", () => {
    // No mask written here: the default asks the engine which sections it writes.
    const json = host.session.perceptionJson();
    say(json ?? "the engine has seen nothing yet");
  });

  button("agent-says", () => {
    const { live, refused } = host.session.textCount();
    if (live === 0) {
      say(refused > 0 ? `nothing readable; ${refused} refused for want of room` : "the frame says nothing, or the text rail is off");
      return;
    }
    say(host.session.readings().map((r) => `"${r.text}" track ${r.trackId} at ${r.confidence.toFixed(2)}`).join("\n"));
  });

  button("agent-remember", () => {
    const landmarks = host.landmarks();
    if (!landmarks) {
      say("no face in the frame to remember");
      return;
    }
    const embedding = embeddingFrom(landmarks);
    if (!embedding) {
      say("the face is too small to make a signature from");
      return;
    }
    // Opened at the width that arrived, once: a caller does not declare a
    // dimension it has already shown.
    if (memoryDim !== embedding.length) {
      host.session.memoryOpen(embedding.length);
      memoryDim = embedding.length;
    }
    const id = nextId;
    nextId += 1;
    say(host.session.remember(id, embedding) ? `remembered ${id}; ${host.session.memoryStats().count} held` : "the memory refused it");
  });

  button("agent-find", () => {
    const landmarks = host.landmarks();
    const embedding = landmarks ? embeddingFrom(landmarks) : null;
    if (!embedding) {
      say("no face in the frame to search with");
      return;
    }
    if (memoryDim === 0) {
      say("nothing is remembered yet");
      return;
    }
    const hits = host.session.memorySearch(embedding, 5);
    say(hits.length === 0 ? "the memory holds nothing like it" : hits.map((h) => `${h.id} at ${h.score.toFixed(4)}`).join(", "));
  });

  button("agent-box", () => {
    const landmarks = host.landmarks();
    if (!landmarks) {
      say("no face to box");
      return;
    }
    let minX = 1;
    let minY = 1;
    let maxX = 0;
    let maxY = 0;
    const count = landmarks.length / 3;
    for (let i = 0; i < count; i += 1) {
      minX = Math.min(minX, landmarks[i * 3]!);
      maxX = Math.max(maxX, landmarks[i * 3]!);
      minY = Math.min(minY, landmarks[i * 3 + 1]!);
      maxY = Math.max(maxY, landmarks[i * 3 + 1]!);
    }
    // A box addressed by one id, with a lifetime: the failure mode of an overlay
    // is annotations nobody removed, so this one expires on its own.
    const box: GossAnnotation = {
      id: 1,
      kind: 0,
      rect: [minX, minY, maxX - minX, maxY - minY],
      colour: [0, 255, 255, 255],
      opacity: 1,
      lifetimeKind: 1,
      lifetimeValue: 180,
    };
    say(host.session.annotate(box, "face") ? "box placed for 180 frames" : "the annotation was refused");
  });

  button("agent-screen", async () => {
    if (share) {
      share.stop();
      share = null;
      say("screen share stopped");
      return;
    }
    share = await shareScreen({ frameRate: 15 });
    if (!share) {
      say("the screen picker was declined, or this browser has none");
      return;
    }
    const centre = host.session.screenPoint(0, 0.5, 0.5);
    const where = centre ? `; the frame's centre is ${centre.desktop[0].toFixed(0)},${centre.desktop[1].toFixed(0)} on the desktop` : "";
    say(`sharing a ${share.surface} at ${share.width}x${share.height}, scale ${share.scale}${where}`);
  });

  // A shared screen is only a source once its frames are submitted, so the rail
  // pumps it on its own rather than asking the render loop to know about it.
  const pump = () => {
    if (share) share.step(host.session, "screen");
    requestAnimationFrame(pump);
  };
  requestAnimationFrame(pump);

  panel.removeAttribute("hidden");
}
