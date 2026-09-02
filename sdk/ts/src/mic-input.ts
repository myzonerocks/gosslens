import type { GossSession } from "./index.js";

/// Captures the microphone and feeds it to the engine's audio analysis,
/// so the level and beat triggers a lens reads fire on web the same way
/// submitted audio drives them on the native SDKs. A worklet forwards
/// each block to the main thread, which hands it to submitAudio.
const captureProcessor = `
class GossMicCapture extends AudioWorkletProcessor {
  process(inputs) {
    const chan = inputs[0] && inputs[0][0];
    if (chan && chan.length) this.port.postMessage(chan.slice());
    return true;
  }
}
registerProcessor("goss-mic-capture", GossMicCapture);
`;

export class GossMicInput {
  private session: GossSession;
  private context: AudioContext | null = null;
  private stream: MediaStream | null = null;
  private node: AudioWorkletNode | null = null;
  private source: MediaStreamAudioSourceNode | null = null;

  constructor(session: GossSession) {
    this.session = session;
  }

  /// Requests the microphone and starts forwarding its PCM to the
  /// engine. Call from a user gesture; browsers gate both getUserMedia
  /// and the AudioContext behind one.
  async start(): Promise<void> {
    if (this.context) return;
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const context = new AudioContext();
    const moduleUrl = URL.createObjectURL(new Blob([captureProcessor], { type: "text/javascript" }));
    try {
      await context.audioWorklet.addModule(moduleUrl);
    } finally {
      URL.revokeObjectURL(moduleUrl);
    }
    const source = context.createMediaStreamSource(stream);
    const node = new AudioWorkletNode(context, "goss-mic-capture", { numberOfOutputs: 0 });
    const rate = context.sampleRate;
    node.port.onmessage = (event) => {
      const block = event.data as Float32Array;
      this.session.submitAudio(block, block.length, rate, 1);
    };
    source.connect(node);
    await context.resume();
    this.context = context;
    this.stream = stream;
    this.source = source;
    this.node = node;
  }

  /// Stops the capture and releases the microphone.
  async stop(): Promise<void> {
    this.source?.disconnect();
    this.node?.disconnect();
    this.source = null;
    this.node = null;
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = null;
    const context = this.context;
    this.context = null;
    if (context) await context.close();
  }
}
