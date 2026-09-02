import type { GossSession } from "./index.js";

/// Plays an MP4 through a hidden video element, the browser's own
/// decoder, and feeds each frame to a named engine source a lens
/// composites, so a web lens shows a video texture with no wasm
/// decoder. The `video.texture` node stays native; this serves web.
export class GossVideoTexture {
  private session: GossSession;
  private name: string;
  private video: HTMLVideoElement;
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D | null;
  private running = false;

  constructor(session: GossSession, name: string, url: string) {
    this.session = session;
    this.name = name;
    this.video = document.createElement("video");
    this.video.src = url;
    this.video.loop = true;
    this.video.muted = true;
    this.video.playsInline = true;
    this.canvas = document.createElement("canvas");
    this.ctx = this.canvas.getContext("2d", { willReadFrequently: true });
  }

  /// Registers the source and starts playback; pumps run from the
  /// frame loop. Call from a user gesture so autoplay is allowed.
  async start(): Promise<void> {
    if (this.running) return;
    this.session.defineSource(this.name);
    await this.video.play();
    this.running = true;
  }

  /// Grabs the current video frame and submits it to the source. Call
  /// once per frame from the same loop that renders the session; a no-op
  /// until the first frame has enough data to draw.
  pump(): void {
    if (!this.running || !this.ctx) return;
    if (this.video.readyState < 2 || this.video.videoWidth === 0) return;
    const w = this.video.videoWidth;
    const h = this.video.videoHeight;
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    this.ctx.drawImage(this.video, 0, 0, w, h);
    const rgba = this.ctx.getImageData(0, 0, w, h).data;
    this.session.submitSourceFrameRgba(this.name, new Uint8Array(rgba.buffer), w, h, w * 4);
  }

  /// Stops playback and releases the element.
  stop(): void {
    this.running = false;
    this.video.pause();
    this.video.removeAttribute("src");
    this.video.load();
  }
}
