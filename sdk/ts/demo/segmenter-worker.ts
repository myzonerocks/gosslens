// The segmenter worker: hosts the segmentation core so the selfie mask
// never blocks the page. The page sends the wasm module and the .tflite
// model once, then RGBA frames; each processed frame answers with the
// subject mask. Frames and masks move as transferred buffers.

import { GossSegmenter } from "../src/tracking";

let segmenter: GossSegmenter | null = null;

interface InitMessage {
  kind: "init";
  moduleBytes: ArrayBuffer;
  modelBytes: ArrayBuffer;
}

interface FrameMessage {
  kind: "frame";
  rgba: ArrayBuffer;
  width: number;
  height: number;
}

self.onmessage = async (event: MessageEvent<InitMessage | FrameMessage>) => {
  const message = event.data;
  if (message.kind === "init") {
    try {
      segmenter = await GossSegmenter.create(message.moduleBytes, new Uint8Array(message.modelBytes));
      self.postMessage({ kind: "ready" });
    } catch (error) {
      self.postMessage({ kind: "error", message: String(error) });
    }
    return;
  }
  if (message.kind === "frame") {
    if (!segmenter) return;
    const mask = segmenter.process(new Uint8Array(message.rgba), message.width, message.height);
    self.postMessage({ kind: "mask", mask: mask ?? null });
  }
};
