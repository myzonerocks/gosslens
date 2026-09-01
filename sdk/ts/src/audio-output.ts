import type { GossSession } from "./index";

/// The worklet drains chunks the page posts it, so the audio thread
/// never touches the wasm heap and the engine's graph-thread pull
/// contract holds; an underrun renders silence.
const processorSource = `
class GossLensAudioProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.queue = [];
    this.offset = 0;
    this.queued = 0;
    this.port.onmessage = (event) => {
      this.queue.push(event.data);
      this.queued += event.data.length;
      while (this.queue.length > 1 && this.queued - this.queue[0].length + this.offset > 16384) {
        this.queued -= this.queue[0].length;
        this.queue.shift();
        this.offset = 0;
      }
    };
  }
  process(_inputs, outputs) {
    const out = outputs[0][0];
    if (!out) return true;
    for (let i = 0; i < out.length; i += 1) {
      const head = this.queue[0];
      if (!head) {
        out[i] = 0;
        continue;
      }
      out[i] = head[this.offset] / 32768;
      this.offset += 1;
      if (this.offset >= head.length) {
        this.queued -= head.length;
        this.queue.shift();
        this.offset = 0;
      }
    }
    return true;
  }
}
registerProcessor("goss-lens-audio", GossLensAudioProcessor);
`;

/// Routes the lens mixer to the page's speakers. The engine pull is
/// graph-thread only, so pump() runs in the frame loop on the main
/// thread and posts each block to an AudioWorklet that plays it.
export class GossAudioOutput {
  /// The lens mixer's fixed output format.
  static readonly sampleRate = 48_000;

  private session: GossSession;
  private context: AudioContext | null = null;
  private node: AudioWorkletNode | null = null;

  constructor(session: GossSession) {
    this.session = session;
  }

  /// Stands the worklet up; browsers require a user gesture before an
  /// AudioContext runs, so call this from one and await it.
  async start(): Promise<void> {
    if (this.context) return;
    const context = new AudioContext({ sampleRate: GossAudioOutput.sampleRate });
    const moduleUrl = URL.createObjectURL(new Blob([processorSource], { type: "text/javascript" }));
    try {
      await context.audioWorklet.addModule(moduleUrl);
    } finally {
      URL.revokeObjectURL(moduleUrl);
    }
    const node = new AudioWorkletNode(context, "goss-lens-audio", {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [1],
    });
    node.connect(context.destination);
    await context.resume();
    this.context = context;
    this.node = node;
  }

  /// Pulls the next mixer block and hands it to the worklet. Call once
  /// per frame from the same loop that ticks the lens. The post
  /// transfers the block's buffer, which detaches it, so each pump is
  /// one fresh small block by design rather than a reusable buffer.
  pump(frames = 800): void {
    const node = this.node;
    if (!node) return;
    const block = this.session.pullAudio(frames);
    node.port.postMessage(block, [block.buffer]);
  }

  /// Tears the worklet and context down.
  async stop(): Promise<void> {
    this.node?.disconnect();
    this.node = null;
    const context = this.context;
    this.context = null;
    if (context) await context.close();
  }
}
