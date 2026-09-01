import { GOSS_SEGMENTATION_MASK_SIDE, GossAudioOutput, GossFaceRegion, GossPreviewSession, pickEngineUrl } from "../src/index.ts";
import { GOSS_FACE_LANDMARK_COUNT } from "../src/tracking.ts";

const status = document.getElementById("status")!;
const canvas = document.getElementById("preview") as HTMLCanvasElement;
const overlay = document.getElementById("overlay") as HTMLCanvasElement;
const background = document.getElementById("background") as HTMLCanvasElement;
const readout = document.getElementById("readout")!;

let proofLogged = false;
// Whether the landmark overlay draws this frame, and the newest fps the
// render loop reported - both feed the on-screen tracking readout.
let overlaysVisible = true;
let latestFps = 0;
// The virtual-background segmenter and its live state. The link stands up
// lazily the first time the toggle turns on, and stays null on a build
// with no segmenter model present.
let segmenterLink: SegmenterLink | null = null;
let virtualBackgroundOn = false;

// The canned gesture classes the hand result scores, in class-index order.
const GESTURE_NAMES = ["none", "fist", "open palm", "point up", "thumb down", "thumb up", "victory", "love"];

interface TrackingReply {
  kind: string;
  message?: string;
  presence: number;
  landmarkCount: number;
  landmarks: Float32Array;
  blendshapes: Float32Array;
}

/// The tracking worker hosts the wasm module; frames go over as
/// transferred buffers and results come back parsed. Replies arrive in
/// send order, so a queue of resolvers pairs them up.
class TrackerLink {
  private worker: Worker;
  private resolvers: Array<(reply: TrackingReply) => void> = [];
  busy = false;

  private constructor(worker: Worker) {
    this.worker = worker;
    worker.onmessage = (event: MessageEvent<TrackingReply>) => {
      if (event.data.kind !== "result") return;
      this.busy = false;
      this.resolvers.shift()?.(event.data);
    };
  }

  static async create(): Promise<TrackerLink> {
    const [moduleBytes, taskBundle] = await Promise.all([
      fetch(new URL("./gosslens_tracking.wasm", import.meta.url)).then((r) => r.arrayBuffer()),
      fetch(new URL("./face_landmarker.task", import.meta.url)).then((r) => r.arrayBuffer()),
    ]);
    const worker = new Worker(new URL("./tracking-worker.js", import.meta.url), { type: "module" });
    await new Promise<void>((resolve, reject) => {
      worker.onerror = (event) => reject(new Error(`worker: ${event.message}`));
      worker.onmessage = (event: MessageEvent<{ kind: string; message?: string }>) => {
        if (event.data.kind === "booted") {
          (window as unknown as Record<string, unknown>).workerBooted = true;
          return;
        }
        if (event.data.kind === "stage") {
          (window as unknown as Record<string, unknown>).workerStage = (event.data as { stage?: string }).stage;
          return;
        }
        if (event.data.kind === "ready") resolve();
        else reject(new Error(event.data.message ?? "tracking worker failed"));
      };
      worker.postMessage({ kind: "init", moduleBytes, taskBundle }, [moduleBytes, taskBundle]);
    });
    return new TrackerLink(worker);
  }

  send(rgba: Uint8ClampedArray, width: number, height: number, timestampUs: number): Promise<TrackingReply> {
    this.busy = true;
    const copy = new Uint8Array(rgba).buffer;
    return new Promise((resolve) => {
      this.resolvers.push(resolve);
      this.worker.postMessage({ kind: "frame", rgba: copy, width, height, timestampUs }, [copy]);
    });
  }
}

/// The segmentation worker hosts the selfie model; frames go over as
/// transferred buffers and the subject mask comes back. One frame in
/// flight at a time, newest wins - the same rhythm the tracker uses.
class SegmenterLink {
  private worker: Worker;
  private resolvers: Array<(mask: Float32Array | null) => void> = [];
  busy = false;

  private constructor(worker: Worker) {
    this.worker = worker;
    worker.onmessage = (event: MessageEvent<{ kind: string; mask?: Float32Array | null }>) => {
      if (event.data.kind !== "mask") return;
      this.busy = false;
      this.resolvers.shift()?.(event.data.mask ?? null);
    };
  }

  static async create(): Promise<SegmenterLink> {
    const [moduleBytes, modelBytes] = await Promise.all([
      fetchRequired("./gosslens_tracking.wasm"),
      fetchRequired("./selfie_multiclass.tflite"),
    ]);
    const worker = new Worker(new URL("./segmenter-worker.js", import.meta.url), { type: "module" });
    await new Promise<void>((resolve, reject) => {
      worker.onerror = (event) => reject(new Error(`worker: ${event.message}`));
      worker.onmessage = (event: MessageEvent<{ kind: string; message?: string }>) => {
        if (event.data.kind === "ready") resolve();
        else if (event.data.kind === "error") reject(new Error(event.data.message ?? "segmenter failed"));
      };
      worker.postMessage({ kind: "init", moduleBytes, modelBytes }, [moduleBytes, modelBytes]);
    });
    return new SegmenterLink(worker);
  }

  send(rgba: Uint8ClampedArray, width: number, height: number): Promise<Float32Array | null> {
    this.busy = true;
    const copy = new Uint8Array(rgba).buffer;
    return new Promise((resolve) => {
      this.resolvers.push(resolve);
      this.worker.postMessage({ kind: "frame", rgba: copy, width, height }, [copy]);
    });
  }
}

/// Fetches an asset, throwing when it is absent - the signal the demo uses
/// to disable the virtual-background toggle rather than crash on a build
/// that never fetched the segmenter model.
async function fetchRequired(url: string): Promise<ArrayBuffer> {
  const response = await fetch(new URL(url, import.meta.url));
  if (!response.ok) throw new Error(`${url} not present (${response.status})`);
  return response.arrayBuffer();
}

/// Paints the blurred camera as a replacement background, then cuts the
/// person region back out from the segmentation mask so the crisp preview
/// underneath shows through. Drawn in the engine's unmirrored space; the
/// page CSS mirrors this canvas to sit exactly over the preview.
const maskScratch = document.createElement("canvas");
function renderVirtualBackground(preview: GossPreviewSession, mask: Float32Array | null): void {
  const ctx = background.getContext("2d")!;
  const width = background.width;
  const height = background.height;
  const video = preview.video;
  if (!mask || video.readyState < 2 || video.videoWidth === 0) {
    ctx.clearRect(0, 0, width, height);
    return;
  }
  ctx.clearRect(0, 0, width, height);
  ctx.globalCompositeOperation = "source-over";
  ctx.filter = "blur(14px)";
  // The analysis frame fed to the segmenter carries the same upside-down
  // correction as the tracker, so the mask lands in this flipped space too.
  if (preview.isVideoFlipped()) {
    ctx.setTransform(1, 0, 0, -1, 0, height);
    ctx.drawImage(video, 0, 0, width, height);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
  } else {
    ctx.drawImage(video, 0, 0, width, height);
  }
  ctx.filter = "none";
  const side = GOSS_SEGMENTATION_MASK_SIDE;
  maskScratch.width = side;
  maskScratch.height = side;
  const maskCtx = maskScratch.getContext("2d")!;
  const image = maskCtx.createImageData(side, side);
  for (let i = 0; i < side * side; i += 1) {
    image.data[i * 4 + 3] = Math.round(Math.min(1, Math.max(0, mask[i]!)) * 255);
  }
  maskCtx.putImageData(image, 0, 0);
  ctx.globalCompositeOperation = "destination-out";
  ctx.drawImage(maskScratch, 0, 0, width, height);
  ctx.globalCompositeOperation = "source-over";
}

/// Frame-pixel landmarks (a hand or a body) painted as dots, scaled from the
/// engine frame's own resolution into the overlay square.
function drawFrameLandmarks(ctx: CanvasRenderingContext2D, landmarks: Float32Array, videoWidth: number, videoHeight: number, color: string, radius: number): void {
  ctx.fillStyle = color;
  const count = landmarks.length / 3;
  for (let i = 0; i < count; i += 1) {
    const x = (landmarks[i * 3]! * overlay.width) / videoWidth;
    const y = (landmarks[i * 3 + 1]! * overlay.height) / videoHeight;
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, Math.PI * 2);
    ctx.fill();
  }
}

/// Landmarks come back in frame pixels; the overlay scales them into its
/// own square and paints one dot each.
function drawOverlay(reply: TrackingReply, frameWidth: number, frameHeight: number): void {
  const ctx = overlay.getContext("2d")!;
  ctx.clearRect(0, 0, overlay.width, overlay.height);
  if (!overlaysVisible) return;
  if (reply.landmarkCount === 0 || reply.presence < 0.5) return;
  const scaleX = overlay.width / frameWidth;
  const scaleY = overlay.height / frameHeight;
  ctx.fillStyle = "#fff";
  for (let index = 0; index < reply.landmarkCount; index += 1) {
    const x = reply.landmarks[index * 3] * scaleX;
    const y = reply.landmarks[index * 3 + 1] * scaleY;
    ctx.fillRect(x - 1, y - 1, 2, 2);
  }
}

async function startTracking(preview: GossPreviewSession): Promise<void> {
  const link = await TrackerLink.create();
  const scratch = document.createElement("canvas");
  const ctx = scratch.getContext("2d", { willReadFrequently: true })!;
  let trackingAnnounced = false;
  let lastReply: TrackingReply | null = null;

  // One analysis frame in flight at a time, always the newest; the live
  // loop samples the camera element at analysis size.
  const analysisWidth = 480;
  const feed = () => {
    requestAnimationFrame(feed);
    if (link.busy) return;
    const video = preview.video;
    if (video.readyState < 2 || video.videoWidth === 0 || video.paused) return;
    const analysisHeight = Math.round((analysisWidth * video.videoHeight) / video.videoWidth);
    scratch.width = analysisWidth;
    scratch.height = analysisHeight;
    if (preview.isVideoFlipped()) {
      ctx.setTransform(1, 0, 0, -1, 0, analysisHeight);
      ctx.drawImage(video, 0, 0, analysisWidth, analysisHeight);
      ctx.setTransform(1, 0, 0, 1, 0, 0);
    } else {
      ctx.drawImage(video, 0, 0, analysisWidth, analysisHeight);
    }
    const pixels = ctx.getImageData(0, 0, analysisWidth, analysisHeight);
    void link.send(pixels.data, analysisWidth, analysisHeight, Math.round(performance.now() * 1000)).then((reply) => {
      // The video can pause (freezeCamera, driving a still-photo test)
      // between this request going out and its reply coming back - a
      // live "no face" result landing after that would silently clear
      // landmarks setLandmarksFromStill just set explicitly for the
      // frozen frame. Stale results while paused are simply dropped.
      if (video.paused) return;
      const present = reply.presence >= 0.5 && reply.landmarkCount > 0;
      lastReply = reply;
      drawOverlay(reply, analysisWidth, analysisHeight);
      preview.setFaceLandmarks(present ? reply.landmarks : null, analysisWidth, analysisHeight);
      // Feed the same face through the multi-face path so it carries a
      // stable track id the readout can show. Landmarks scale from the
      // analysis frame into the engine frame's own resolution here.
      const videoWidth = preview.video.videoWidth;
      const videoHeight = preview.video.videoHeight;
      if (present && videoWidth > 0) {
        const framePoints = new Float32Array(reply.landmarkCount * 3);
        const sx = videoWidth / analysisWidth;
        const sy = videoHeight / analysisHeight;
        for (let i = 0; i < reply.landmarkCount; i += 1) {
          framePoints[i * 3] = reply.landmarks[i * 3]! * sx;
          framePoints[i * 3 + 1] = reply.landmarks[i * 3 + 1]! * sy;
          framePoints[i * 3 + 2] = reply.landmarks[i * 3 + 2]!;
        }
        preview.session.submitFaces([{ landmarks: framePoints, presence: reply.presence }]);
      } else {
        preview.session.submitFaces([]);
      }
      // Overlay the nose-tip attach marker plus any hand and body dots the
      // engine reports, each drawn only when its result is present.
      if (overlaysVisible && videoWidth > 0) {
        const octx = overlay.getContext("2d")!;
        const nose = preview.session.faceRegion(GossFaceRegion.NoseTip);
        if (nose) {
          octx.fillStyle = "#0ff";
          octx.beginPath();
          octx.arc((nose[0] * overlay.width) / videoWidth, (nose[1] * overlay.height) / videoHeight, 6, 0, Math.PI * 2);
          octx.fill();
        }
        const hand = preview.session.handResult();
        if (hand) for (const one of hand.hands) drawFrameLandmarks(octx, one.landmarks, videoWidth, videoHeight, "#ff0", 3);
        const pose = preview.session.poseResult();
        if (pose && pose.landmarkCount > 0) drawFrameLandmarks(octx, pose.landmarks, videoWidth, videoHeight, "#0f0", 3);
      }
      if (!trackingAnnounced) {
        trackingAnnounced = true;
        console.log(`GOSSWEB tracking running: serial results flowing, presence ${reply.presence.toFixed(3)}`);
      }
    });
    // The virtual background runs the selfie segmenter over the same
    // analysis frame, then composites a blurred background from its mask.
    if (virtualBackgroundOn && segmenterLink && !segmenterLink.busy) {
      void segmenterLink.send(pixels.data, analysisWidth, analysisHeight).then((mask) => {
        if (!virtualBackgroundOn || preview.video.paused) return;
        preview.session.setSegmentationMask(mask);
        renderVirtualBackground(preview, mask);
      });
    }
  };
  requestAnimationFrame(feed);

  // Ticks the active lens at display refresh rate with the newest
  // tracking result's signals, the same rhythm the iOS demo drives -
  // paused (a frozen still-photo test) means the prover owns ticking.
  let lastLensTick = performance.now();
  let audioOutput: GossAudioOutput | null = null;
  const lensTick = () => {
    requestAnimationFrame(lensTick);
    const now = performance.now();
    const dtUs = Math.max(0, Math.round((now - lastLensTick) * 1000));
    lastLensTick = now;
    // One status line: face presence, the stable track id, the hand's
    // canned gesture, and the live fps.
    const facePresent = (lastReply?.presence ?? 0) >= 0.5 && (lastReply?.landmarkCount ?? 0) > 0;
    const trackId = preview.session.faceTrackId(0);
    const gestureIndex = preview.session.handResult()?.hands[0]?.gesture ?? 0;
    const gesture = GESTURE_NAMES[gestureIndex] ?? "none";
    readout.textContent = `face ${facePresent ? "yes" : "no"}  id:${trackId ?? "-"}  gesture:${gesture}  ${latestFps.toFixed(0)} fps`;
    if (preview.video.paused) return;
    preview.tickLens(dtUs, {
      hasFace: (lastReply?.presence ?? 0) >= 0.5 && (lastReply?.landmarkCount ?? 0) > 0,
      blendshapes: lastReply?.blendshapes,
    });
    audioOutput?.pump();
  };
  requestAnimationFrame(lensTick);

  // The still-image path the prover drives: one fetched image through the
  // same worker, resolved with the parsed result.
  (window as unknown as Record<string, unknown>).trackImage = async (url: string) => {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const still = document.createElement("canvas");
    still.width = bitmap.width;
    still.height = bitmap.height;
    const stillCtx = still.getContext("2d", { willReadFrequently: true })!;
    stillCtx.drawImage(bitmap, 0, 0);
    const pixels = stillCtx.getImageData(0, 0, still.width, still.height);
    const reply = await link.send(pixels.data, still.width, still.height, 0);
    return {
      presence: reply.presence,
      landmarkCount: reply.landmarkCount,
      expected: GOSS_FACE_LANDMARK_COUNT,
    };
  };
  // Same still-image path, but for reshape's own proof: tracks the image
  // and feeds the result straight into the preview session's face
  // contour, the way the live feed loop above does every frame.
  (window as unknown as Record<string, unknown>).setLandmarksFromStill = async (url: string) => {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const still = document.createElement("canvas");
    still.width = bitmap.width;
    still.height = bitmap.height;
    const stillCtx = still.getContext("2d", { willReadFrequently: true })!;
    stillCtx.drawImage(bitmap, 0, 0);
    const pixels = stillCtx.getImageData(0, 0, still.width, still.height);
    const reply = await link.send(pixels.data, still.width, still.height, 0);
    preview.setFaceLandmarks(
      reply.presence >= 0.5 && reply.landmarkCount > 0 ? reply.landmarks : null,
      still.width,
      still.height,
    );
  };
  (window as unknown as Record<string, unknown>).trackingUp = true;
}

async function run(): Promise<void> {
  const webgpuUrl = new URL("./webgpu/gosslens_web.js", import.meta.url);
  const webgl2Url = new URL("./gosslens_web.js", import.meta.url);
  // ?engine=webgpu|webgl2 forces a specific build for testing both
  // paths independently - real Chrome always has a working adapter,
  // so the auto-detect in pickEngineUrl alone can never exercise the
  // WebGL2 fallback here.
  const forcedEngine = new URLSearchParams(location.search).get("engine");
  const wasmJsUrl =
    forcedEngine === "webgpu" ? webgpuUrl : forcedEngine === "webgl2" ? webgl2Url : await pickEngineUrl(webgpuUrl, webgl2Url);
  const preview = await GossPreviewSession.create(canvas, wasmJsUrl, {
    onState(state) {
      status.textContent = `capture ${state}`;
      document.title = `gosslens ${state}`;
    },
    onFps(fps, rendered, cameraFrames) {
      latestFps = fps;
      const level = preview.degradeLevel();
      status.textContent = `capture ${preview.state}  ${fps.toFixed(1)} fps  frames ${cameraFrames}  degrade ${level}`;
      // Claimed before the read starts, not after it resolves - the
      // WebGPU build's own readCenterPixel is a real async engine call,
      // and this fires once per rAF tick, so without an early claim
      // several ticks would each start their own capture before the
      // first one's promise settles.
      if (!proofLogged && cameraFrames > 30 && fps > 20) {
        proofLogged = true;
        preview.readCenterPixel().then((pixel) => {
          const lit = pixel[0] + pixel[1] + pixel[2] > 0;
          if (!lit) {
            proofLogged = false;
            return;
          }
          const line = `GOSSWEB preview active: ${cameraFrames} camera frames at ${fps.toFixed(1)} fps, center pixel ${pixel[0]},${pixel[1]},${pixel[2]}`;
          console.log(line);
          document.title = line;
          const div = document.createElement("div");
          div.id = "proof";
          div.textContent = line;
          document.body.appendChild(div);
        });
      }
    },
  });

  // Lens sounds route to the speakers; browsers gate audio behind a
  // gesture, so the first tap stands the worklet up and the lens tick
  // loop pumps it each frame.
  window.addEventListener(
    "pointerdown",
    () => {
      const output = new GossAudioOutput(preview.session);
      output.start().then(() => {
        audioOutput = output;
      });
    },
    { once: true },
  );
  await preview.start();
  // Persisted across reloads: a camera that hands the browser
  // pre-rotated frames does so every time, not just this once. Default
  // true on a device that's never recorded a choice - this demo's own
  // camera does this consistently, so "never asked" should mean
  // "already correct," not "upside down until you notice and fix it."
  const flipCameraCheckbox = document.getElementById("flip-camera") as HTMLInputElement | null;
  const flipRaw = localStorage.getItem("gossweb-flip-camera");
  const flipStored = flipRaw === null ? true : flipRaw === "1";
  if (flipCameraCheckbox) {
    flipCameraCheckbox.checked = flipStored;
    preview.setVideoFlip(flipStored);
    flipCameraCheckbox.addEventListener("change", () => {
      preview.setVideoFlip(flipCameraCheckbox.checked);
      localStorage.setItem("gossweb-flip-camera", flipCameraCheckbox.checked ? "1" : "0");
    });
  }
  startTracking(preview).catch((err) => {
    (window as unknown as Record<string, unknown>).trackingError = String(err);
    console.log(`tracking unavailable: ${String(err)}`);
  });

  await preview.loadWhitenLuts(new URL("./res/", import.meta.url));
  const whitenSlider = document.getElementById("whiten") as HTMLInputElement | null;
  whitenSlider?.addEventListener("input", () => {
    preview.setWhiten(Number(whitenSlider.value));
  });
  (window as unknown as Record<string, unknown>).setWhiten = (value: number) => {
    preview.setWhiten(value);
  };
  const smoothSlider = document.getElementById("smooth") as HTMLInputElement | null;
  smoothSlider?.addEventListener("input", () => {
    preview.setSmooth(Number(smoothSlider.value));
  });
  (window as unknown as Record<string, unknown>).setSmooth = (value: number) => {
    preview.setSmooth(value);
  };
  const thinFaceSlider = document.getElementById("thin-face") as HTMLInputElement | null;
  thinFaceSlider?.addEventListener("input", () => {
    preview.setThinFace(Number(thinFaceSlider.value));
  });
  (window as unknown as Record<string, unknown>).setThinFace = (value: number) => {
    preview.setThinFace(value);
  };
  const bigEyeSlider = document.getElementById("big-eye") as HTMLInputElement | null;
  bigEyeSlider?.addEventListener("input", () => {
    preview.setBigEye(Number(bigEyeSlider.value));
  });
  (window as unknown as Record<string, unknown>).setBigEye = (value: number) => {
    preview.setBigEye(value);
  };
  await preview.loadMakeupTextures(new URL("./res/", import.meta.url));
  const lipstickSlider = document.getElementById("lipstick") as HTMLInputElement | null;
  lipstickSlider?.addEventListener("input", () => {
    preview.setLipstick(Number(lipstickSlider.value));
  });
  (window as unknown as Record<string, unknown>).setLipstick = (value: number) => {
    preview.setLipstick(value);
  };
  const blushSlider = document.getElementById("blush") as HTMLInputElement | null;
  blushSlider?.addEventListener("input", () => {
    preview.setBlush(Number(blushSlider.value));
  });

  // The asset-free post-effect lenses run straight from json (no bundle
  // directory), so the buttons swap them in as a live filter over the camera.
  const filterLenses: Record<string, string> = {
    blur: '{"glf":"1.0","id":"goss.demo.blur","version":"1.0.0","display_name":"Blur","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"b","type":"blur.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[]}',
    grade: '{"glf":"1.0","id":"goss.demo.grade","version":"1.0.0","display_name":"Grade","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"g","type":"grade.pass","inputs":{"frame":"camera"},"params":{},"grade":{"exposure":0.12,"contrast":1.15,"saturation":1.2,"temperature":0.06}}],"triggers":[]}',
    bloom: '{"glf":"1.0","id":"goss.demo.bloom","version":"1.0.0","display_name":"Bloom","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"m","type":"bloom.pass","inputs":{"frame":"camera"},"params":{},"bloom":{"threshold":0.6,"intensity":0.8}}],"triggers":[]}',
    ember: '{"glf":"1.0","id":"goss.demo.ember","version":"1.0.0","display_name":"Ember","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"e","type":"model.gltf","inputs":{"frame":"camera"},"params":{},"particles":{"count":200,"gravity":3.0,"speed":0.5,"lifetime":1.5,"fade":true,"cool":[0.7,0.05,0.0],"size":8,"glow":true}}],"triggers":[]}',
  };
  document.getElementById("filter-none")?.addEventListener("click", () => preview.deactivateLens());
  for (const name of ["blur", "grade", "bloom", "ember"]) {
    document.getElementById(`filter-${name}`)?.addEventListener("click", () => preview.activateLens(filterLenses[name]));
  }
  (window as unknown as Record<string, unknown>).setBlush = (value: number) => {
    preview.setBlush(value);
  };
  (window as unknown as Record<string, unknown>).makeupTexturesReady = true;
  (window as unknown as Record<string, unknown>).loadStillFrame = (url: string) => preview.loadStillFrame(url);
  (window as unknown as Record<string, unknown>).readCenterPixel = async () => Array.from(await preview.readCenterPixel());
  (window as unknown as Record<string, unknown>).readFrameSum = () => preview.readFrameSum();
  (window as unknown as Record<string, unknown>).captureFrame = () => preview.captureFrame();
  (window as unknown as Record<string, unknown>).activateLens = async (url: string) => {
    const manifestJson = await (await fetch(url)).text();
    preview.activateLens(manifestJson);
  };
  (window as unknown as Record<string, unknown>).deactivateLens = () => preview.deactivateLens();
  (window as unknown as Record<string, unknown>).tickLens = (dtUs: number) => preview.tickLens(dtUs);
  // Pausing the video element stops the per-frame texture re-upload,
  // freezing whatever the shader is currently sampling.
  (window as unknown as Record<string, unknown>).freezeCamera = () => preview.video.pause();
  (window as unknown as Record<string, unknown>).resumeCamera = () => preview.video.play();
  (window as unknown as Record<string, unknown>).whitenLutsReady = true;

  // Capture the composited frame to a PNG and show it. The engine frame is
  // unmirrored; a front camera stays mirrored, so the mirror is baked into
  // the saved photo, and the virtual background is drawn over it when on.
  const shot = document.getElementById("shot") as HTMLImageElement | null;
  document.getElementById("capture")?.addEventListener("click", async () => {
    if (!shot) return;
    const dataUrl = await preview.captureFrame();
    const frame = new Image();
    await new Promise<void>((resolve, reject) => {
      frame.onload = () => resolve();
      frame.onerror = () => reject(new Error("capture decode failed"));
      frame.src = dataUrl;
    });
    const out = document.createElement("canvas");
    out.width = canvas.width;
    out.height = canvas.height;
    const octx = out.getContext("2d")!;
    octx.translate(out.width, 0);
    octx.scale(-1, 1);
    octx.drawImage(frame, 0, 0, out.width, out.height);
    if (virtualBackgroundOn) octx.drawImage(background, 0, 0, out.width, out.height);
    shot.src = out.toDataURL("image/png");
    shot.style.display = "block";
  });

  // The tracking overlay toggle: hide the dots without stopping tracking.
  const overlayToggle = document.getElementById("show-overlays") as HTMLInputElement | null;
  overlayToggle?.addEventListener("change", () => {
    overlaysVisible = overlayToggle.checked;
    if (!overlaysVisible) overlay.getContext("2d")!.clearRect(0, 0, overlay.width, overlay.height);
  });

  // The virtual background stands the selfie segmenter up on first use.
  // With no model present the toggle disables itself with a short note
  // rather than crashing.
  const vbCheckbox = document.getElementById("virtual-bg") as HTMLInputElement | null;
  const vbNote = document.getElementById("vbg-note");
  if (vbCheckbox && vbNote) {
    try {
      const probe = await fetch(new URL("./selfie_multiclass.tflite", import.meta.url), { method: "HEAD" });
      if (!probe.ok) throw new Error("absent");
    } catch {
      vbCheckbox.disabled = true;
      vbNote.textContent = "no segmenter model";
    }
    vbCheckbox.addEventListener("change", async () => {
      if (!vbCheckbox.checked) {
        virtualBackgroundOn = false;
        vbNote.textContent = "";
        preview.session.setSegmentationMask(null);
        background.getContext("2d")!.clearRect(0, 0, background.width, background.height);
        return;
      }
      vbCheckbox.disabled = true;
      vbNote.textContent = "loading";
      try {
        if (!segmenterLink) segmenterLink = await SegmenterLink.create();
        virtualBackgroundOn = true;
        vbNote.textContent = "";
        vbCheckbox.disabled = false;
      } catch (err) {
        virtualBackgroundOn = false;
        vbCheckbox.checked = false;
        vbCheckbox.disabled = true;
        vbNote.textContent = "no segmenter model";
        console.log(`virtual background unavailable: ${String(err)}`);
      }
    });
  }
}

run().catch((err) => {
  status.textContent = String(err);
});
