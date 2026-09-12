//! Screens on the web. getDisplayMedia is the browser's own consent dialog and
//! its own picker, so there is no enumeration to do here: the user chooses, and
//! what comes back says which kind of surface it is.

import { GossPixelFormat, type GossSession } from "./index.js";

/// What the user picked. The browser reports this on the track, and it is the
/// only place the surface kind is knowable: a page cannot enumerate displays.
export type GossDisplaySurface = "monitor" | "window" | "browser" | "unknown";

export interface GossScreenShare {
  /// The live track, so a caller can stop it or watch it end.
  readonly track: MediaStreamTrack;
  readonly surface: GossDisplaySurface;
  /// Backing pixels, which on a scaled display is not the CSS size.
  readonly width: number;
  readonly height: number;
  /// The scale the browser applied, so a coordinate sent back maps to a pixel.
  readonly scale: number;
  /// Submits the newest frame under a source name. False when no new frame has
  /// arrived, so a still screen costs nothing.
  step(session: GossSession, source?: string): boolean;
  stop(): void;
}

/// Opens the browser's screen picker. Rejecting the dialog is a refusal, not an
/// error: the caller gets null and prompts again when it makes sense to.
export async function shareScreen(options: { audio?: boolean; frameRate?: number } = {}): Promise<GossScreenShare | null> {
  const media = navigator.mediaDevices as MediaDevices & {
    getDisplayMedia?: (constraints: MediaStreamConstraints) => Promise<MediaStream>;
  };
  if (typeof media?.getDisplayMedia !== "function") return null;

  let stream: MediaStream;
  try {
    stream = await media.getDisplayMedia({
      video: options.frameRate ? { frameRate: options.frameRate } : true,
      audio: options.audio ?? false,
    });
  } catch {
    // The user declined, or the browser refused. Both are answers.
    return null;
  }

  const track = stream.getVideoTracks()[0];
  if (!track) {
    stream.getTracks().forEach((t) => t.stop());
    return null;
  }

  const settings = track.getSettings() as MediaTrackSettings & { displaySurface?: string };
  const width = settings.width ?? 0;
  const height = settings.height ?? 0;
  const surface: GossDisplaySurface =
    settings.displaySurface === "monitor" || settings.displaySurface === "window" || settings.displaySurface === "browser"
      ? settings.displaySurface
      : "unknown";

  // An OffscreenCanvas where one exists, because drawing the frame is the only
  // way a page reads pixels out of a track and a visible canvas would need a DOM.
  const canvas = typeof OffscreenCanvas === "function"
    ? new OffscreenCanvas(Math.max(width, 1), Math.max(height, 1))
    : Object.assign(document.createElement("canvas"), { width: Math.max(width, 1), height: Math.max(height, 1) });
  const context = (canvas as OffscreenCanvas).getContext("2d") as OffscreenCanvasRenderingContext2D | null;
  const video = document.createElement("video");
  video.srcObject = stream;
  video.muted = true;
  await video.play().catch(() => undefined);

  let lastTime = -1;
  return {
    track,
    surface,
    width,
    height,
    scale: typeof devicePixelRatio === "number" ? devicePixelRatio : 1,
    step(session: GossSession, source = ""): boolean {
      if (!context || video.readyState < 2) return false;
      // The same frame twice is not a new frame, which is what makes a static
      // screen free rather than a copy per tick.
      if (video.currentTime === lastTime) return false;
      lastTime = video.currentTime;
      context.drawImage(video as unknown as CanvasImageSource, 0, 0, canvas.width, canvas.height);
      const image = context.getImageData(0, 0, canvas.width, canvas.height);
      const pixels = new Uint8Array(image.data.buffer);
      const timestampUs = Math.round(video.currentTime * 1e6);
      if (source.length === 0) {
        session.submitFrameRgbaCopy(pixels, canvas.width * 4, canvas.width, canvas.height, GossPixelFormat.Rgba8, undefined, false, timestampUs);
      } else {
        session.submitSourceFrameRgba(source, pixels, canvas.width, canvas.height, canvas.width * 4);
      }
      return true;
    },
    stop() {
      stream.getTracks().forEach((t) => t.stop());
      video.srcObject = null;
    },
  };
}
