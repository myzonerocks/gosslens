// The web SDK over gosslens_web, the real bgfx-backed engine every
// other SDK already runs (Swift/Kotlin call the exact same frozen ABI
// through their own thin platform glue). This SDK owns only what the
// browser forces on it - camera capture through getUserMedia, decoding
// PNGs the core has no decoder for, driving the render loop - and hands
// everything else (the frame graph, all six beauty effects, mirror and
// rotation) straight to the engine.

export const GOSS_OK = 0;

export const enum GossDegradeLevel {
  Full = 0,
  ReducedMlCadence = 1,
  SegmentationOff = 2,
  BeautySimplified = 3,
  Passthrough = 4,
}

export const enum GossBeautyEffect {
  Smooth = 0,
  Whiten = 1,
  ThinFace = 2,
  BigEye = 3,
  Lipstick = 4,
  Blush = 5,
}

/// Platform thermal pressure. No browser API surfaces device thermal
/// state, so web callers report nominal unless they know better.
export const enum GossThermal {
  Nominal = 0,
  Fair = 1,
  Serious = 2,
  Critical = 3,
}

/// Pixel layout of a submitted frame, mirroring the frozen C enum.
export const enum GossPixelFormat {
  Nv12 = 0,
  Nv21 = 1,
  I420 = 2,
  Bgra8 = 3,
  Rgba8 = 4,
}

export const enum GossColorStandard {
  Bt601 = 0,
  Bt709 = 1,
  Bt2020 = 2,
}

export const enum GossColorRange {
  Video = 0,
  Full = 1,
}

/// The live signals one tick evaluates a lens's compiled triggers
/// against. hasFace false means every face-driven signal reads as false
/// regardless of what blendshapes holds.
export interface GossLensSignals {
  hasFace?: boolean;
  handsPresent?: boolean;
  tap?: boolean;
  worldTrackingState?: number;
  audioLevel?: number;
  blendshapes?: Float32Array | readonly number[];
}

/// Frame-path pool bounds; omitted fields mean the built-in default.
export interface GossEngineConfig {
  texturePoolCapacity?: number;
  stagingPoolCapacity?: number;
}

/// Whole-pipeline frame budget; omitted means the built-in default (30 fps).
export interface GossSessionConfig {
  frameBudgetUs?: number;
}

/// A high-resolution still capture, decoupled from the preview size. width
/// and height 0 capture at the submitted frame's own resolution; format is
/// PNG (0), JPEG (1) or HEIC (2); quality is 1..100 for the lossy formats.
export interface GossStillConfig {
  width?: number;
  height?: number;
  supersample?: number;
  format?: number;
  quality?: number;
  /** 0 = sRGB, 1 = Display-P3, 2 = Rec2020 - the gamut the file is tagged with. */
  colorSpace?: number;
  /** 8 or 16 bits per channel; 16 is the PNG high-bit-depth path. */
  bitDepth?: number;
}

const FRAME_FLAG_MIRROR = 0x1;
const FRAME_ROTATION_SHIFT = 8;
const LENS_SIGNALS_BYTES = 232;
const GOSS_FACE_BLENDSHAPE_COUNT = 52;
export const GOSS_FACE_LANDMARK_COUNT = 478;
export const GOSS_FACE_MAX = 4;
const FACE_RESULT_BYTES = 5968;
export const GOSS_SEGMENTATION_MASK_SIDE = 256;

/// A face handed to submitFaces for the multi-face path. landmarks are frame
/// pixels, GOSS_FACE_LANDMARK_COUNT * 3 floats; presence defaults to 1 and a
/// face below the tracked threshold is dropped by the engine.
export interface GossFaceInput {
  landmarks: Float32Array;
  presence?: number;
  blendshapes?: Float32Array;
  frameSerial?: number;
  timestampUs?: bigint;
}

/// One face read back from faceResultAt, the frozen goss_face_result laid out.
export interface GossFaceOut {
  frameSerial: bigint;
  timestampUs: bigint;
  presence: number;
  landmarkCount: number;
  landmarks: Float32Array;
  blendshapes: Float32Array;
}

export const GOSS_POSE_LANDMARK_COUNT = 33;
export const GOSS_BODY_MAX = 4;
const POSE_RESULT_BYTES = 688;

/// A body handed to submitBodies for the multi-person path. landmarks are
/// frame pixels, GOSS_POSE_LANDMARK_COUNT * 3 floats; presence defaults to 1
/// and a body below the tracked threshold is dropped by the engine.
export interface GossPoseInput {
  landmarks: Float32Array;
  presence?: number;
  visibilities?: Float32Array;
  presences?: Float32Array;
  frameSerial?: number;
  timestampUs?: bigint;
}

/// One body read back from bodyResultAt, the frozen goss_pose_result laid out.
export interface GossPoseOut {
  frameSerial: bigint;
  timestampUs: bigint;
  presence: number;
  landmarkCount: number;
  landmarks: Float32Array;
  visibilities: Float32Array;
  presences: Float32Array;
}

/// A named attach point on the tracked face mesh, for faceRegion. The
/// left/right labels are the subject's own.
export enum GossFaceRegion {
  Forehead = 0,
  Glabella = 1,
  NoseTip = 2,
  Chin = 3,
  LeftEye = 4,
  RightEye = 5,
  LeftCheek = 6,
  RightCheek = 7,
  LeftEar = 8,
  RightEar = 9,
  MouthCenter = 10,
  LeftMouthCorner = 11,
  RightMouthCorner = 12,
}

/// A named attach point on the tracked body skeleton, for bodyJoint. The
/// left/right labels are the subject's own.
export enum GossBodyJoint {
  Head = 0,
  LeftShoulder = 1,
  RightShoulder = 2,
  LeftElbow = 3,
  RightElbow = 4,
  LeftWrist = 5,
  RightWrist = 6,
  LeftHip = 7,
  RightHip = 8,
  LeftKnee = 9,
  RightKnee = 10,
  LeftAnkle = 11,
  RightAnkle = 12,
}

/// A named attach point on a tracked hand, for handJoint. Palm is the
/// middle-finger knuckle, a stable palm-centre proxy.
export enum GossHandJoint {
  Wrist = 0,
  ThumbTip = 1,
  IndexTip = 2,
  MiddleTip = 3,
  RingTip = 4,
  PinkyTip = 5,
  Palm = 6,
}

/// The segmentation mask channels a lens can name, in the engine's frozen
/// order: the derived person mask, then the multiclass model's own labels.
/// Index 0 (person) rides the subject mask; the rest upload as class masks.
export const GOSS_SEGMENTATION_CHANNELS = [
  "person",
  "background",
  "hair",
  "body_skin",
  "face_skin",
  "clothes",
  "others",
] as const;

export type GossCaptureState = "idle" | "running" | "denied" | "failed" | "interrupted";

export interface GossSessionEvents {
  onState?(state: GossCaptureState): void;
  onFps?(fps: number, renderedFrames: number, cameraFrames: number): void;
}

/// Emscripten's own Module surface, the pieces this SDK actually uses.
/// EXPORTED_RUNTIME_METHODS in build.zig's wasm-emscripten link step is
/// the source of truth for what's actually present at runtime.
interface EngineModule {
  HEAPU8: Uint8Array;
  HEAP16: Int16Array;
  HEAP32: Int32Array;
  HEAPF32: Float32Array;
  HEAPF64: Float64Array;
  ccall(name: string, returnType: string | null, argTypes: string[], args: unknown[]): number;
  ccall(name: string, returnType: string | null, argTypes: string[], args: unknown[], opts: { async: true }): Promise<number>;
  getValue(ptr: number, type: string): number;
  setValue(ptr: number, value: number, type: string): void;
  stringToNewUTF8(value: string): number;
}

type EngineModuleFactory = (overrides?: Record<string, unknown>) => Promise<EngineModule>;

/// Decodes a fetched blob to raw RGBA bytes via a 2D canvas. Unlike
/// texImage2D (see the git history on this file - a real, hard-won
/// lesson from the old hand-rolled WebGL2 SDK this one replaces),
/// getImageData has always had simple, browser-consistent semantics:
/// row 0 is the visual top of the image, full stop. No DOM-source
/// orientation quirks to work around, because there's no texImage2D
/// involved at all - just plain bytes handed to the engine's own
/// texture upload, which owns its own orientation convention entirely
/// separately from WebGL's.
/// fit, when given, downscales (never upscales) so the decoded frame
/// fits within maxWidth/maxHeight - LUT and makeup textures pass
/// nothing and decode at native resolution; loadStillFrame passes the
/// canvas's own size, since a corpus photo can be far larger than a
/// real camera frame ever would be. The composite chain sizes every
/// offscreen target and the final swap-chain view rect off the
/// submitted frame's own dimensions, so a frame wider or taller than
/// the actual WebGL drawing buffer gets silently clipped by the GPU to
/// whatever corner overlaps it - real, found via a still photo (2400x
/// 3000) submitted straight through to a 1280x720 canvas, where only
/// the top-left ~13% ended up visible and every landmark-driven effect
/// (thin-face, big-eye, lipstick, blush) happened to warp a region
/// entirely outside that sliver, reading back as no change at all.
async function decodeImageRgba(
  blob: Blob,
  fit?: { maxWidth: number; maxHeight: number },
): Promise<{ data: Uint8ClampedArray; width: number; height: number }> {
  const bitmap = await createImageBitmap(blob);
  const scale = fit ? Math.min(1, fit.maxWidth / bitmap.width, fit.maxHeight / bitmap.height) : 1;
  const width = Math.round(bitmap.width * scale);
  const height = Math.round(bitmap.height * scale);
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d")!;
  ctx.drawImage(bitmap, 0, 0, width, height);
  const image = ctx.getImageData(0, 0, width, height);
  return { data: image.data, width, height };
}

/// Chooses which gosslens_web.js build to load: the WebGPU one (bgfx's
/// WebGPU backend, Asyncify linked in) or the WebGL2 one (no Asyncify).
/// Two separate artifacts rather than a runtime toggle, since Asyncify
/// taxes the whole per-frame path, not just init. Checks for a real
/// working adapter, not just navigator.gpu's presence, which can exist
/// with no adapter behind it.
export async function pickEngineUrl(webgpuUrl: string | URL, webgl2Url: string | URL): Promise<string | URL> {
  const gpu = (navigator as unknown as { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
  if (!gpu) return webgl2Url;
  try {
    const adapter = await gpu.requestAdapter();
    return adapter ? webgpuUrl : webgl2Url;
  } catch {
    return webgl2Url;
  }
}

/// ABI bootstrap: the loaded wasm module plus the two free functions,
/// the same role Kotlin's Gosslens object plays around
/// System.loadLibrary. Module load needs a canvas here, unlike
/// Swift/Kotlin - a real platform difference, not an inconsistency.

/// The platform camera's tracking quality: 0 unavailable, 1
/// initializing, 2 tracking, 3 limited.
export interface GossWorldState {
  trackingState: number;
  worldFromCamera: ArrayLike<number>;
  projection: ArrayLike<number>;
  timestampUs: number;
}

export interface GossWorldPlane {
  id: number;
  pose: ArrayLike<number>;
  extentX: number;
  extentZ: number;
  classification: number;
}

export interface GossWorldAnchorInput {
  id: number;
  pose: ArrayLike<number>;
}

export interface GossWorldLight {
  ambientIntensity: number;
  colorTemperatureKelvin: number;
}

export class Gosslens {
  private constructor(
    private readonly mod: EngineModule,
    private readonly version: number,
  ) {}

  /// Any-thread. Compare the high 16 bits against the header's own
  /// GOSS_ABI_MAJOR before creating anything - load() already has.
  abiVersion(): number {
    return this.version;
  }

  /// Loads gosslens_web.js and checks its ABI major version. A
  /// dynamic import, not static: bun's bundler would otherwise inline
  /// this file, breaking Emscripten's own import.meta.url-relative
  /// fetch of gosslens_web.wasm sitting next to it.
  static async load(canvas: HTMLCanvasElement, wasmJsUrl: string | URL): Promise<Gosslens> {
    const imported = (await import(/* @vite-ignore */ String(wasmJsUrl))) as { default: EngineModuleFactory };
    const mod = await imported.default({ canvas });
    const version = mod.ccall("goss_abi_version", "number", [], []) >>> 0;
    if (version >> 16 !== 0) throw new Error(`gosslens abi major mismatch: ${version >> 16}`);
    return new Gosslens(mod, version);
  }

  /// The YCbCr to RGB conversion for a standard and range as one
  /// column-major homogeneous matrix. Unused today (canvas always
  /// yields RGBA already) - a real gap for any future debug/thumbnail
  /// path, kept wrapped so that path doesn't start from a raw ccall.
  yuvToRgb(colorStandard: GossColorStandard, colorRange: GossColorRange): Float32Array {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [64]);
    this.mod.ccall("goss_color_yuv_to_rgb", "number", ["number", "number", "number"], [colorStandard, colorRange, ptr]);
    const out = new Float32Array(16);
    for (let i = 0; i < 16; i += 1) out[i] = this.mod.getValue(ptr + i * 4, "float");
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 64]);
    return out;
  }

  /// Analytic two-bone inverse kinematics for a limb: root, the upper and lower
  /// bone lengths, target, and pole (each [x, y, z]); returns the mid joint and
  /// end. An out-of-reach target extends the limb straight at it.
  solveTwoBoneIk(root: [number, number, number], upperLen: number, lowerLen: number, target: [number, number, number], pole: [number, number, number]): { mid: [number, number, number]; end: [number, number, number] } {
    const rp = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const tp = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const pp = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const mp = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const ep = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    this.mod.HEAPF32.set(root, rp >> 2);
    this.mod.HEAPF32.set(target, tp >> 2);
    this.mod.HEAPF32.set(pole, pp >> 2);
    this.mod.ccall("goss_solve_two_bone_ik", "number", ["number", "number", "number", "number", "number", "number", "number"], [rp, upperLen, lowerLen, tp, pp, mp, ep]);
    const mw = mp >> 2;
    const ew = ep >> 2;
    const mid: [number, number, number] = [this.mod.HEAPF32[mw]!, this.mod.HEAPF32[mw + 1]!, this.mod.HEAPF32[mw + 2]!];
    const end: [number, number, number] = [this.mod.HEAPF32[ew]!, this.mod.HEAPF32[ew + 1]!, this.mod.HEAPF32[ew + 2]!];
    for (const p of [rp, tp, pp, mp, ep]) this.mod.ccall("goss_free", null, ["number", "number"], [p, 12]);
    return { mid, end };
  }

  /// @internal - GossEngine/GossSession need the raw module to reach the ABI;
  /// nothing outside this file should call ccall directly.
  get module(): EngineModule {
    return this.mod;
  }
}

/// Render-surface lifecycle: create/resize/render/read back. Confined
/// to the one canvas it was created against, matching GossSession/GossEngine's
/// single-thread confinement on every other SDK.
export class GossEngine {
  private captureInFlight = false;
  private canvas: HTMLCanvasElement | null = null;
  /// Only set on the WebGL2 build - bgfx's WebGPU backend binds the
  /// canvas to a 'webgpu' context instead, and a canvas can only ever
  /// bind one context type for its lifetime. capturePixels() branches
  /// on this: readPixels when set, goss_engine_capture_frame otherwise.
  private gl: WebGL2RenderingContext | null = null;

  private constructor(
    private readonly mod: EngineModule,
    readonly handle: number,
  ) {}

  static create(gosslens: Gosslens, config?: GossEngineConfig): GossEngine {
    const mod = gosslens.module;
    let configPtr = 0;
    if (config) {
      configPtr = mod.ccall("goss_alloc", "number", ["number"], [8]);
      mod.setValue(configPtr, config.texturePoolCapacity ?? 0, "i32");
      mod.setValue(configPtr + 4, config.stagingPoolCapacity ?? 0, "i32");
    }
    const engineOut = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const engineStatus = mod.ccall("goss_engine_create", "number", ["number", "number"], [configPtr, engineOut]);
    const handle = mod.getValue(engineOut, "i32");
    mod.ccall("goss_free", null, ["number", "number"], [engineOut, 4]);
    if (configPtr !== 0) mod.ccall("goss_free", null, ["number", "number"], [configPtr, 8]);
    if (engineStatus !== GOSS_OK) throw new Error(`engine create failed: ${engineStatus}`);
    return new GossEngine(mod, handle);
  }

  /// @internal - GossSession needs the raw module to reach the ABI; nothing
  /// outside this file should call ccall directly.
  get module(): EngineModule {
    return this.mod;
  }

  /// Brings the render backend up against canvas, which needs a stable
  /// id: bgfx's own HTML5 backend resolves it via a #id selector string
  /// (glcontext_html5.cpp), separate from the Module.canvas binding
  /// Gosslens.load already made - both must agree.
  async initRenderer(canvas: HTMLCanvasElement): Promise<void> {
    if (!canvas.id) throw new Error("canvas needs a stable id for bgfx's own selector lookup");
    const mod = this.mod;
    const selectorPtr = mod.stringToNewUTF8(`#${canvas.id}`);
    const rendererDescPtr = mod.ccall("goss_alloc", "number", ["number"], [12]);
    mod.setValue(rendererDescPtr, selectorPtr, "i32");
    mod.setValue(rendererDescPtr + 4, canvas.width, "i32");
    mod.setValue(rendererDescPtr + 8, canvas.height, "i32");
    // bgfx's own HTML5 backend creates this canvas's WebGL2 context
    // itself, via emscripten_webgl_create_context - passing
    // webGLContextAttributes here has no effect regardless,
    // preserveDrawingBuffer stays false. Worked around in capturePixels.
    const rendererStatus = await mod.ccall("goss_engine_init_renderer", "number", ["number", "number"], [this.handle, rendererDescPtr], { async: true });
    mod.ccall("goss_free", null, ["number", "number"], [rendererDescPtr, 12]);
    if (rendererStatus !== GOSS_OK) throw new Error(`renderer init failed: ${rendererStatus}`);

    // Emscripten's C++ side just created this canvas's own rendering
    // context; a repeat getContext returns that same context. webgpu
    // first: a webgpu-bound canvas answers a mismatched
    // getContext("webgl2") with null, never the wrong context.
    this.canvas = canvas;
    this.gl = canvas.getContext("webgpu") ? null : canvas.getContext("webgl2");
  }

  resize(width: number, height: number): void {
    if (!this.canvas) throw new Error("initRenderer first");
    this.canvas.width = width;
    this.canvas.height = height;
    this.mod.ccall("goss_engine_resize", null, ["number", "number", "number"], [this.handle, width, height]);
  }

  /// A null session presents the clear color, matching every other
  /// SDK's own goss_engine_render_frame contract.
  renderFrame(session: GossSession | null): number {
    return this.mod.ccall("goss_engine_render_frame", "number", ["number", "number"], [this.handle, session?.handle ?? 0]);
  }

  /// Releases the persistent wrap the engine keeps per external live
  /// texture handle - the pair of the native SDKs' renderToLiveTexture,
  /// for a host retiring a publish surface before the engine goes away.
  /// False for a handle with no live wrap.
  releaseLiveTexture(nativeHandle: bigint): boolean {
    return this.mod.ccall("goss_engine_release_live_texture", "number", ["number", "number"], [this.handle, nativeHandle]) === 0;
  }

  /// The two ways this SDK reads pixels back: bgfx's WebGL2 context
  /// never preserves its drawing buffer, so readPixels runs right after
  /// a fresh render; WebGPU has no sync equivalent, so
  /// goss_engine_capture_frame runs async, mapping a GPU buffer.
  private async capturePixels(session: GossSession | null): Promise<{ pixels: Uint8Array; width: number; height: number }> {
    if (!this.canvas) throw new Error("initRenderer first");
    if (this.gl) {
      const gl = this.gl;
      this.renderFrame(session);
      const width = this.canvas.width;
      const height = this.canvas.height;
      const pixels = new Uint8Array(width * height * 4);
      gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      return { pixels, width, height };
    }

    const capacity = this.canvas.width * this.canvas.height * 4;
    const dataPtr = this.mod.ccall("goss_alloc", "number", ["number"], [capacity]);
    const outWidthPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    const outHeightPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    this.captureInFlight = true;
    try {
      const status = await this.mod.ccall(
        "goss_engine_capture_frame",
        "number",
        ["number", "number", "number", "number", "number", "number"],
        [this.handle, session?.handle ?? 0, dataPtr, capacity, outWidthPtr, outHeightPtr],
        { async: true },
      );
      if (status !== GOSS_OK) throw new Error(`goss_engine_capture_frame failed: status ${status}`);
      const width = this.mod.getValue(outWidthPtr, "i32");
      const height = this.mod.getValue(outHeightPtr, "i32");
      const pixels = this.mod.HEAPU8.slice(dataPtr, dataPtr + width * height * 4);
      return { pixels, width, height };
    } finally {
      this.captureInFlight = false;
      this.mod.ccall("goss_free", null, ["number", "number"], [dataPtr, capacity]);
      this.mod.ccall("goss_free", null, ["number", "number"], [outWidthPtr, 4]);
      this.mod.ccall("goss_free", null, ["number", "number"], [outHeightPtr, 4]);
    }
  }

  /// goss_engine_capture_frame on the WebGPU build is an async
  /// (Asyncify-suspending) ccall - calling renderFrame while one is in
  /// flight would reenter the wasm module synchronously, which
  /// Asyncify does not support while already suspended.
  get isCaptureInFlight(): boolean {
    return this.captureInFlight;
  }

  /// PNG-encodes the current frame. Test/debug tooling: a real image
  /// beats a frame-sum heuristic for verifying a landmark-driven effect
  /// actually landed where it should, not just that something changed
  /// somewhere.
  async captureFrame(session: GossSession | null): Promise<string> {
    const { pixels, width: w, height: h } = await this.capturePixels(session);
    const out = document.createElement("canvas");
    out.width = w;
    out.height = h;
    const ctx = out.getContext("2d")!;
    const imageData = ctx.createImageData(w, h);
    if (this.gl) {
      const rowBytes = w * 4;
      for (let y = 0; y < h; y += 1) {
        const srcStart = (h - 1 - y) * rowBytes;
        imageData.data.set(pixels.subarray(srcStart, srcStart + rowBytes), y * rowBytes);
      }
    } else {
      imageData.data.set(pixels);
    }
    ctx.putImageData(imageData, 0, 0);
    return out.toDataURL("image/png");
  }

  /// The composited frame as packed bytes in a WebRTC format (BGRA or RGBA),
  /// the supported per-frame output for a live source. On the web the canvas is
  /// already a zero-copy source through captureStream(); reach for this only for
  /// raw pixels. NV12 is the native encoders' path - captureStream handles web.
  async captureLiveFrame(session: GossSession | null, format: GossPixelFormat = GossPixelFormat.Bgra8): Promise<{ pixels: Uint8Array; width: number; height: number }> {
    if (format !== GossPixelFormat.Bgra8 && format !== GossPixelFormat.Rgba8) {
      throw new Error("captureLiveFrame on web supports Bgra8 or Rgba8; use captureStream for a live track");
    }
    const { pixels, width, height } = await this.capturePixels(session);
    if (format === GossPixelFormat.Bgra8) {
      for (let i = 0; i + 3 < pixels.length; i += 4) {
        const red = pixels[i];
        pixels[i] = pixels[i + 2];
        pixels[i + 2] = red;
      }
    }
    return { pixels, width, height };
  }

  /// A high-resolution still of the composited frame at its own resolution
  /// (width and height 0) or a requested one, decoupled from the preview
  /// size, returned as the encoded image bytes. Wasm core only: the pure
  /// WebGL path renders in JS and has no core encoder to reach.
  async captureStill(session: GossSession | null, config: GossStillConfig = {}): Promise<Uint8Array> {
    if (this.gl) throw new Error("captureStill needs the wasm renderer");
    const cfgPtr = this.mod.ccall("goss_alloc", "number", ["number"], [28]);
    this.mod.setValue(cfgPtr, config.width ?? 0, "i32");
    this.mod.setValue(cfgPtr + 4, config.height ?? 0, "i32");
    this.mod.setValue(cfgPtr + 8, config.supersample ?? 0, "i32");
    this.mod.setValue(cfgPtr + 12, config.format ?? 0, "i32");
    this.mod.setValue(cfgPtr + 16, config.quality ?? 0, "i32");
    this.mod.setValue(cfgPtr + 20, config.colorSpace ?? 0, "i32");
    this.mod.setValue(cfgPtr + 24, config.bitDepth ?? 8, "i32");
    const lenPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    const widthPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    const heightPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    let dataPtr = 0;
    let capacity = 0;
    this.captureInFlight = true;
    try {
      // Probe for the encoded size, then capture into a buffer of that size.
      const probeArgs = ["number", "number", "number", "number", "number", "number", "number", "number"];
      const probeStatus = await this.mod.ccall(
        "goss_engine_capture_still",
        "number",
        probeArgs,
        [this.handle, session?.handle ?? 0, cfgPtr, 0, 0, lenPtr, widthPtr, heightPtr],
        { async: true },
      );
      capacity = this.mod.getValue(lenPtr, "i32");
      if (probeStatus === GOSS_OK && capacity === 0) return new Uint8Array(0);
      if (capacity <= 0) throw new Error(`goss_engine_capture_still probe failed: status ${probeStatus}`);
      dataPtr = this.mod.ccall("goss_alloc", "number", ["number"], [capacity]);
      const status = await this.mod.ccall(
        "goss_engine_capture_still",
        "number",
        probeArgs,
        [this.handle, session?.handle ?? 0, cfgPtr, dataPtr, capacity, lenPtr, widthPtr, heightPtr],
        { async: true },
      );
      if (status !== GOSS_OK) throw new Error(`goss_engine_capture_still failed: status ${status}`);
      const encoded = this.mod.getValue(lenPtr, "i32");
      return this.mod.HEAPU8.slice(dataPtr, dataPtr + encoded);
    } finally {
      this.captureInFlight = false;
      this.mod.ccall("goss_free", null, ["number", "number"], [cfgPtr, 28]);
      this.mod.ccall("goss_free", null, ["number", "number"], [lenPtr, 4]);
      this.mod.ccall("goss_free", null, ["number", "number"], [widthPtr, 4]);
      this.mod.ccall("goss_free", null, ["number", "number"], [heightPtr, 4]);
      if (dataPtr !== 0) this.mod.ccall("goss_free", null, ["number", "number"], [dataPtr, capacity]);
    }
  }

  /// The composited frame encoded as a deterministic PNG - the same
  /// pixels, the same bytes - at the submitted frame's own resolution.
  /// captureStill is the configurable superset (a chosen size, JPEG, or a
  /// wider gamut); this is the plain PNG surface. Wasm core only.
  async capturePhoto(session: GossSession | null): Promise<Uint8Array> {
    return this.captureEncoded(
      "goss_engine_capture_photo",
      ["number", "number", "number", "number", "number", "number", "number"],
      (dataPtr, capacity, lenPtr, widthPtr, heightPtr) => [this.handle, session?.handle ?? 0, dataPtr, capacity, lenPtr, widthPtr, heightPtr],
    );
  }

  /// The composited frame as a platform photo: format 1 is JPEG at quality
  /// 1..100 (the engine's own encoder, present on web too), format 2 is HEIC
  /// (the native photo backend, GOSS_UNSUPPORTED on web). Lossy and not
  /// bit-stable across runs, so capturePhoto stays the deterministic path.
  async capturePhotoAs(session: GossSession | null, format: number, quality = 90): Promise<Uint8Array> {
    return this.captureEncoded(
      "goss_engine_capture_photo_as",
      ["number", "number", "number", "number", "number", "number", "number", "number", "number"],
      (dataPtr, capacity, lenPtr, widthPtr, heightPtr) => [this.handle, session?.handle ?? 0, format, quality, dataPtr, capacity, lenPtr, widthPtr, heightPtr],
    );
  }

  /// The probe-then-capture the encoded-photo ABI ops share: render and encode
  /// once into a one-byte buffer to learn the exact size (the encoders write
  /// out_len before rejecting a too-small capacity), then capture into a buffer
  /// of that size. Wasm core only, like captureStill; WebGL2 renders in JS.
  private async captureEncoded(
    callName: string,
    argTypes: string[],
    buildArgs: (dataPtr: number, capacity: number, lenPtr: number, widthPtr: number, heightPtr: number) => unknown[],
  ): Promise<Uint8Array> {
    if (this.gl) throw new Error(`${callName} needs the wasm renderer`);
    const mod = this.mod;
    const lenPtr = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const widthPtr = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const heightPtr = mod.ccall("goss_alloc", "number", ["number"], [4]);
    // A one-byte buffer keeps the probe past the ABI's null-pointer guard so
    // the encoder runs and reports the real size through lenPtr.
    const probePtr = mod.ccall("goss_alloc", "number", ["number"], [1]);
    let dataPtr = 0;
    let capacity = 0;
    this.captureInFlight = true;
    try {
      const probeStatus = await mod.ccall(callName, "number", argTypes, buildArgs(probePtr, 0, lenPtr, widthPtr, heightPtr), { async: true });
      capacity = mod.getValue(lenPtr, "i32");
      if (capacity === 0) return new Uint8Array(0);
      if (capacity < 0) throw new Error(`${callName} probe failed: status ${probeStatus}`);
      dataPtr = mod.ccall("goss_alloc", "number", ["number"], [capacity]);
      const status = await mod.ccall(callName, "number", argTypes, buildArgs(dataPtr, capacity, lenPtr, widthPtr, heightPtr), { async: true });
      if (status !== GOSS_OK) throw new Error(`${callName} failed: status ${status}`);
      const encoded = mod.getValue(lenPtr, "i32");
      return mod.HEAPU8.slice(dataPtr, dataPtr + encoded);
    } finally {
      this.captureInFlight = false;
      mod.ccall("goss_free", null, ["number", "number"], [probePtr, 1]);
      mod.ccall("goss_free", null, ["number", "number"], [lenPtr, 4]);
      mod.ccall("goss_free", null, ["number", "number"], [widthPtr, 4]);
      mod.ccall("goss_free", null, ["number", "number"], [heightPtr, 4]);
      if (dataPtr !== 0) mod.ccall("goss_free", null, ["number", "number"], [dataPtr, capacity]);
    }
  }

  async readCenterPixel(session: GossSession | null): Promise<Uint8Array> {
    const { pixels, width, height } = await this.capturePixels(session);
    const offset = (Math.floor(height / 2) * width + Math.floor(width / 2)) * 4;
    return pixels.slice(offset, offset + 4);
  }

  /// Sums every RGBA byte over the whole canvas - courser but far more
  /// robust than one fixed pixel, since a synthetic test pattern
  /// (Chrome's fake capture device) is free to put its "lit" content
  /// anywhere, leaving any single coordinate dark for long stretches.
  async readFrameSum(session: GossSession | null): Promise<number> {
    const { pixels } = await this.capturePixels(session);
    let sum = 0;
    for (const value of pixels) sum += value;
    return sum;
  }

  destroy(): void {
    this.mod.ccall("goss_engine_destroy", null, ["number"], [this.handle]);
  }
}

/// Declarative camera-hardware intent. The engine normalizes every field; the
/// page reads it back and applies it via getUserMedia track constraints. Modes:
/// flash 0 off/1 on/2 auto; focus 0 auto/1 locked/2 point; exposure 0 auto/1
/// locked. Points normalized 0..1.
export interface GossCameraControls {
  flashMode: number;
  torch: number;
  focusMode: number;
  exposureMode: number;
  focusPointX: number;
  focusPointY: number;
  exposureLinked: number;
  exposurePointX: number;
  exposurePointY: number;
  exposureBiasEv: number;
  zoomFactor: number;
  maxZoomFactor: number;
  mirrorSavePolicy: number;
}

export interface GossRecordingPolicy {
  maxDurationMs: number;
  minClipMs: number;
  segmentMode: number;
  loopPlayback: number;
  speedPreset: number;
  micMuted: number;
  saveOriginal: number;
  stabilization: number;
}

export interface GossCaptureUi {
  gridMode: number;
  levelIndicator: number;
  shutterMode: number;
  countdownS: number;
  nightMode: number;
  screenFlashMode: number;
  screenFlashIntensity: number;
  screenFlashWarmth: number;
}

/// Per-preview runtime: frame submission, beauty, tracking, lens. Owns
/// its own scratch allocations (frame descriptor, pixel buffer,
/// landmarks) rather than one shared per-engine pool - matches every
/// other SDK's own per-session confinement.
export class GossSession {
  private worldScratchPtr = 0;
  private worldScratchLen = 0;
  private frameWidth = 0;
  private frameHeight = 0;
  /// Some cameras (certain external/virtual devices on macOS) hand the
  /// browser frames pre-rotated 180 degrees. Carried as a quarter-turn
  /// count on the submitted frame's own flags, the same mechanism
  /// every other SDK uses for sensor orientation.
  private videoFlipped = false;
  private whitenLutsLoaded = 0;
  private lipstickTextureLoaded = false;
  private blushTextureLoaded = false;
  /// Reused across frames, grown on resize rather than alloc/freed every
  /// tick - the frame descriptor is a fixed 32 bytes, the pixel buffer
  /// tracks the video's current resolution.
  private readonly frameDescPtr: number;
  private framePixelsPtr = 0;
  private framePixelsCapacity = 0;
  /// Fixed capacity: GOSS_FACE_LANDMARK_COUNT never changes.
  private readonly landmarksPtr: number;
  /// Fixed layout, reused every tick like the frame descriptor.
  private readonly signalsPtr: number;
  /// Fixed capacity: the segmentation mask is always mask_side squared.
  private readonly segmentationMaskPtr: number;

  private constructor(
    private readonly mod: EngineModule,
    readonly handle: number,
  ) {
    this.frameDescPtr = mod.ccall("goss_alloc", "number", ["number"], [32]);
    this.landmarksPtr = mod.ccall("goss_alloc", "number", ["number"], [GOSS_FACE_LANDMARK_COUNT * 3 * 4]);
    this.signalsPtr = mod.ccall("goss_alloc", "number", ["number"], [LENS_SIGNALS_BYTES]);
    this.segmentationMaskPtr = mod.ccall("goss_alloc", "number", ["number"], [GOSS_SEGMENTATION_MASK_SIDE * GOSS_SEGMENTATION_MASK_SIDE * 4]);
  }

  static create(engine: GossEngine, config?: GossSessionConfig): GossSession {
    const mod = engine.module;
    let configPtr = 0;
    if (config) {
      configPtr = mod.ccall("goss_alloc", "number", ["number"], [8]);
      mod.setValue(configPtr, config.frameBudgetUs ?? 0, "i32");
      mod.setValue(configPtr + 4, 0, "i32");
    }
    const sessionOut = mod.ccall("goss_alloc", "number", ["number"], [4]);
    const status = mod.ccall("goss_session_create", "number", ["number", "number", "number"], [engine.handle, configPtr, sessionOut]);
    const handle = mod.getValue(sessionOut, "i32");
    mod.ccall("goss_free", null, ["number", "number"], [sessionOut, 4]);
    if (configPtr !== 0) mod.ccall("goss_free", null, ["number", "number"], [configPtr, 8]);
    if (status !== GOSS_OK) throw new Error(`session create failed: ${status}`);
    return new GossSession(mod, handle);
  }

  setWhiten(amount: number): void {
    this.setBeauty(GossBeautyEffect.Whiten, this.whitenLutsLoaded === 4 ? amount : 0);
  }

  setSmooth(amount: number): void {
    this.setBeauty(GossBeautyEffect.Smooth, amount);
  }

  setThinFace(amount: number): void {
    this.setBeauty(GossBeautyEffect.ThinFace, amount);
  }

  setBigEye(amount: number): void {
    this.setBeauty(GossBeautyEffect.BigEye, amount);
  }

  setLipstick(amount: number): void {
    this.setBeauty(GossBeautyEffect.Lipstick, this.lipstickTextureLoaded ? amount : 0);
  }

  setBlush(amount: number): void {
    this.setBeauty(GossBeautyEffect.Blush, this.blushTextureLoaded ? amount : 0);
  }

  setBeauty(effect: GossBeautyEffect, amount: number): void {
    this.mod.ccall("goss_session_set_beauty", "number", ["number", "number", "number"], [this.handle, effect, amount]);
  }

  /// Activates a lens from its manifest JSON directly (goss_session_
  /// activate_lens, not the directory-based variant) - the only
  /// activation path this build actually supports: has_file_io is
  /// comptime-false for every wasm target, so goss_session_activate_lens_
  /// from_directory always reports unsupported here, and shader.pass/
  /// lut.pass/blend.pass nodes need compiled resources a bundle
  /// directory would provide that this SDK has no way to supply yet.
  /// A lens built entirely from beauty.* nodes (beauty-baseline, say)
  /// activates and runs for real regardless, since those go through
  /// applyWebBeautyChain's own embedded shaders, not a per-lens one.
  activateLens(manifestJson: string): void {
    const bytes = new TextEncoder().encode(manifestJson);
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes.length]);
    this.mod.HEAPU8.set(bytes, ptr);
    this.mod.ccall("goss_session_activate_lens", "number", ["number", "number", "number"], [this.handle, ptr, bytes.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes.length]);
  }

  deactivateLens(): void {
    this.mod.ccall("goss_session_deactivate_lens", null, ["number"], [this.handle]);
  }

  /// Advances the active lens's triggers/param ramps by dtUs, evaluating
  /// them against signals - omitted fields read as false/zero, so a bare
  /// tickLens(dtUs) only fires triggers with no `when` gate.
  tickLens(dtUs: number, signals: GossLensSignals = {}): void {
    const ptr = this.signalsPtr;
    this.mod.HEAPU8.fill(0, ptr, ptr + LENS_SIGNALS_BYTES);
    this.mod.HEAPU8[ptr] = signals.hasFace ? 1 : 0;
    this.mod.HEAPU8[ptr + 1] = signals.handsPresent ? 1 : 0;
    this.mod.HEAPU8[ptr + 2] = signals.tap ? 1 : 0;
    this.mod.setValue(ptr + 8, signals.worldTrackingState ?? 0, "double");
    this.mod.setValue(ptr + 16, signals.audioLevel ?? 0, "double");
    if (signals.blendshapes) {
      const base = (ptr + 24) >> 2;
      const count = Math.min(GOSS_FACE_BLENDSHAPE_COUNT, signals.blendshapes.length);
      for (let at = 0; at < count; at += 1) this.mod.HEAPF32[base + at] = signals.blendshapes[at]!;
    }
    this.mod.ccall("goss_session_tick_lens", "number", ["number", "number", "number"], [this.handle, dtUs, ptr]);
  }

  /// Reads a live parameter of the active lens by name, including whatever a
  /// script node last wrote. Null with no active lens or no such parameter.
  parameterValue(name: string): number | null {
    const bytes = new TextEncoder().encode(name);
    const namePtr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes.length]);
    this.mod.HEAPU8.set(bytes, namePtr);
    const outPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]);
    const status = this.mod.ccall("goss_session_parameter_value", "number", ["number", "number", "number", "number"], [this.handle, namePtr, bytes.length, outPtr]);
    const value = status === 0 ? this.mod.getValue(outPtr, "float") : null;
    this.mod.ccall("goss_free", null, ["number", "number"], [namePtr, bytes.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [outPtr, 4]);
    return value;
  }

  /// Feeds interleaved f32 PCM into the session's own level and beat
  /// analysis, which drives the audio.level and audio.beat lens triggers.
  /// samples holds frameCount * channels floats; timestampUs is carried for a
  /// muxed recording track, unused by the web preview path.
  submitAudio(samples: Float32Array, frameCount: number, sampleRate: number, channels: number, timestampUs: bigint = 0n): void {
    const bytes = samples.length * 4;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    this.mod.HEAPF32.set(samples, ptr >> 2);
    this.mod.ccall(
      "goss_session_submit_audio",
      "number",
      ["number", "number", "number", "number", "number", "number"],
      [this.handle, ptr, frameCount, sampleRate, channels, timestampUs],
    );
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes]);
  }

  /// Pulls the next block of mixed lens audio (frames interleaved s16) that
  /// play_sound triggers produced, for the page to feed into WebAudio.
  pullAudio(frames: number): Int16Array {
    const byteLen = frames * 2;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [byteLen]);
    this.mod.ccall("goss_session_pull_audio", "number", ["number", "number", "number"], [this.handle, ptr, frames]);
    const out = new Int16Array(this.mod.HEAP16.buffer, ptr, frames).slice();
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, byteLen]);
    return out;
  }

  /// Folds the active lens sound into the caller's outgoing call/live track:
  /// `mic` (interleaved f32 at `sampleRate`/`channels`, or null for silence)
  /// summed with the 48 kHz mono lens mixer resampled to that rate; returns the
  /// mixed interleaved s16. Advances the mixer once, replacing `pullAudio`.
  mixOutputAudio(mic: Float32Array | null, frameCount: number, sampleRate: number, channels: number): Int16Array {
    const outLen = frameCount * channels;
    const outBytes = outLen * 2;
    const outPtr = this.mod.ccall("goss_alloc", "number", ["number"], [outBytes]);
    let micPtr = 0;
    const micBytes = mic ? mic.length * 4 : 0;
    if (mic) {
      micPtr = this.mod.ccall("goss_alloc", "number", ["number"], [micBytes]);
      this.mod.HEAPF32.set(mic, micPtr >> 2);
    }
    this.mod.ccall(
      "goss_session_mix_output_audio",
      "number",
      ["number", "number", "number", "number", "number", "number"],
      [this.handle, micPtr, outPtr, frameCount, sampleRate, channels],
    );
    const out = new Int16Array(this.mod.HEAP16.buffer, outPtr, outLen).slice();
    this.mod.ccall("goss_free", null, ["number", "number"], [outPtr, outBytes]);
    if (mic) this.mod.ccall("goss_free", null, ["number", "number"], [micPtr, micBytes]);
    return out;
  }

  /// Stores validated camera-hardware intent; the engine normalizes it. Read it
  /// back with `cameraControls` and apply it via getUserMedia track constraints.
  setCameraControls(c: GossCameraControls): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [56]) as number;
    const w = ptr >> 2;
    this.mod.HEAP32[w] = c.flashMode; this.mod.HEAP32[w + 1] = c.torch;
    this.mod.HEAP32[w + 2] = c.focusMode; this.mod.HEAP32[w + 3] = c.exposureMode;
    this.mod.HEAPF32[w + 4] = c.focusPointX; this.mod.HEAPF32[w + 5] = c.focusPointY;
    this.mod.HEAP32[w + 6] = c.exposureLinked;
    this.mod.HEAPF32[w + 7] = c.exposurePointX; this.mod.HEAPF32[w + 8] = c.exposurePointY;
    this.mod.HEAPF32[w + 9] = c.exposureBiasEv; this.mod.HEAPF32[w + 10] = c.zoomFactor;
    this.mod.HEAPF32[w + 11] = c.maxZoomFactor; this.mod.HEAP32[w + 12] = c.mirrorSavePolicy;
    this.mod.HEAP32[w + 13] = 0;
    this.mod.ccall("goss_session_set_camera_controls", "number", ["number", "number"], [this.handle, ptr]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 56]);
  }

  /// The normalized camera controls for the page to apply to the media track.
  cameraControls(): GossCameraControls {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [56]) as number;
    this.mod.ccall("goss_session_camera_controls", "number", ["number", "number"], [this.handle, ptr]);
    const w = ptr >> 2;
    const c: GossCameraControls = {
      flashMode: this.mod.HEAP32[w], torch: this.mod.HEAP32[w + 1],
      focusMode: this.mod.HEAP32[w + 2], exposureMode: this.mod.HEAP32[w + 3],
      focusPointX: this.mod.HEAPF32[w + 4], focusPointY: this.mod.HEAPF32[w + 5],
      exposureLinked: this.mod.HEAP32[w + 6],
      exposurePointX: this.mod.HEAPF32[w + 7], exposurePointY: this.mod.HEAPF32[w + 8],
      exposureBiasEv: this.mod.HEAPF32[w + 9], zoomFactor: this.mod.HEAPF32[w + 10],
      maxZoomFactor: this.mod.HEAPF32[w + 11], mirrorSavePolicy: this.mod.HEAP32[w + 12],
    };
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 56]);
    return c;
  }

  /// Stores the recording policy the app applies to MediaRecorder. The engine
  /// normalizes it; read it back with `recordingPolicy`.
  setRecordingPolicy(p: GossRecordingPolicy): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [40]) as number;
    const w = ptr >> 2;
    this.mod.HEAP32[w] = p.maxDurationMs; this.mod.HEAP32[w + 1] = p.minClipMs;
    this.mod.HEAP32[w + 2] = p.segmentMode; this.mod.HEAP32[w + 3] = p.loopPlayback;
    this.mod.HEAP32[w + 4] = p.speedPreset; this.mod.HEAP32[w + 5] = p.micMuted;
    this.mod.HEAP32[w + 6] = p.saveOriginal; this.mod.HEAP32[w + 7] = p.stabilization;
    this.mod.HEAP32[w + 8] = 0; this.mod.HEAP32[w + 9] = 0;
    this.mod.ccall("goss_session_set_recording_policy", "number", ["number", "number"], [this.handle, ptr]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 40]);
  }

  recordingPolicy(): GossRecordingPolicy {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [40]) as number;
    this.mod.ccall("goss_session_recording_policy", "number", ["number", "number"], [this.handle, ptr]);
    const w = ptr >> 2;
    const p: GossRecordingPolicy = {
      maxDurationMs: this.mod.HEAP32[w], minClipMs: this.mod.HEAP32[w + 1],
      segmentMode: this.mod.HEAP32[w + 2], loopPlayback: this.mod.HEAP32[w + 3],
      speedPreset: this.mod.HEAP32[w + 4], micMuted: this.mod.HEAP32[w + 5],
      saveOriginal: this.mod.HEAP32[w + 6], stabilization: this.mod.HEAP32[w + 7],
    };
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 40]);
    return p;
  }

  /// Stores the capture-UI intent the page renders (grid, timer, night mode, the
  /// front-screen flash). The engine normalizes it; read it back with `captureUi`.
  setCaptureUi(u: GossCaptureUi): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [40]) as number;
    const w = ptr >> 2;
    this.mod.HEAP32[w] = u.gridMode; this.mod.HEAP32[w + 1] = u.levelIndicator;
    this.mod.HEAP32[w + 2] = u.shutterMode; this.mod.HEAP32[w + 3] = u.countdownS;
    this.mod.HEAP32[w + 4] = u.nightMode; this.mod.HEAP32[w + 5] = u.screenFlashMode;
    this.mod.HEAPF32[w + 6] = u.screenFlashIntensity; this.mod.HEAPF32[w + 7] = u.screenFlashWarmth;
    this.mod.HEAP32[w + 8] = 0; this.mod.HEAP32[w + 9] = 0;
    this.mod.ccall("goss_session_set_capture_ui", "number", ["number", "number"], [this.handle, ptr]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 40]);
  }

  captureUi(): GossCaptureUi {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [40]) as number;
    this.mod.ccall("goss_session_capture_ui", "number", ["number", "number"], [this.handle, ptr]);
    const w = ptr >> 2;
    const u: GossCaptureUi = {
      gridMode: this.mod.HEAP32[w], levelIndicator: this.mod.HEAP32[w + 1],
      shutterMode: this.mod.HEAP32[w + 2], countdownS: this.mod.HEAP32[w + 3],
      nightMode: this.mod.HEAP32[w + 4], screenFlashMode: this.mod.HEAP32[w + 5],
      screenFlashIntensity: this.mod.HEAPF32[w + 6], screenFlashWarmth: this.mod.HEAPF32[w + 7],
    };
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 40]);
    return u;
  }

  /// Fires a named event the next `tickLens` delivers to the lens's
  /// `event('name')` triggers for one tick.
  fireEvent(name: string): void {
    const bytes = new TextEncoder().encode(name);
    if (bytes.length === 0) return;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes.length]) as number;
    this.mod.HEAPU8.set(bytes, ptr);
    this.mod.ccall("goss_session_fire_event", "number", ["number", "number", "number"], [this.handle, ptr, bytes.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes.length]);
  }

  private withName(name: string, fn: (ptr: number, len: number) => void): void {
    const bytes = new TextEncoder().encode(name);
    if (bytes.length === 0) return;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes.length]) as number;
    this.mod.HEAPU8.set(bytes, ptr);
    fn(ptr, bytes.length);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes.length]);
  }

  /// Registers a named RGBA source for multi-source composition (Duet, Stitch,
  /// live grids). The camera is the implicit source 0.
  defineSource(name: string): void {
    this.withName(name, (ptr, len) =>
      this.mod.ccall("goss_session_define_source", "number", ["number", "number", "number"], [this.handle, ptr, len]));
  }

  removeSource(name: string): void {
    this.withName(name, (ptr, len) =>
      this.mod.ccall("goss_session_remove_source", "number", ["number", "number", "number"], [this.handle, ptr, len]));
  }

  /// Uploads one RGBA/BGRA frame into a named source (pixelFormat 3 BGRA, 4 RGBA).
  submitSourceFrameRgba(name: string, rgba: Uint8Array, width: number, height: number, stride: number, pixelFormat: GossPixelFormat = GossPixelFormat.Rgba8): void {
    const byteLen = stride * height;
    const rgbaPtr = this.mod.ccall("goss_alloc", "number", ["number"], [byteLen]) as number;
    this.mod.HEAPU8.set(rgba.subarray(0, byteLen), rgbaPtr);
    this.mod.setValue(this.frameDescPtr, width, "i32");
    this.mod.setValue(this.frameDescPtr + 4, height, "i32");
    this.mod.setValue(this.frameDescPtr + 8, pixelFormat, "i32");
    this.mod.setValue(this.frameDescPtr + 12, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 16, 1, "i32");
    this.mod.setValue(this.frameDescPtr + 20, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 24, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 28, 0, "i32");
    this.withName(name, (ptr, len) =>
      this.mod.ccall("goss_session_submit_source_frame_rgba_copy", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, ptr, len, this.frameDescPtr, rgbaPtr, stride]));
    this.mod.ccall("goss_free", null, ["number", "number"], [rgbaPtr, byteLen]);
  }

  /// Arranges the camera and named sources: 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid.
  setLayout(arrangement: number): void {
    this.mod.ccall("goss_session_set_layout", "number", ["number", "number"], [this.handle, arrangement]);
  }

  /// Upper-body pose mode: while enabled the tracked pose reports only the upper
  /// body; the lower-body joints (knees down) read absent.
  setPoseUpperBody(enabled: boolean): void {
    this.mod.ccall("goss_session_set_pose_upper_body", "number", ["number", "number"], [this.handle, enabled ? 1 : 0]);
  }

  clearLayout(): void {
    this.mod.ccall("goss_session_clear_layout", "number", ["number"], [this.handle]);
  }

  /// Sets a source's composite blend: opacity, key mode (0 none, 1 matte, 2
  /// chroma), chroma color, similarity. The name "camera" is the base.
  setSourceComposite(name: string, opacity = 1, keyMode = 0, chroma: [number, number, number] = [0, 0, 0], similarity = 0): void {
    this.withName(name, (ptr, len) =>
      this.mod.ccall("goss_session_set_source_composite", "number", ["number", "number", "number", "number", "number", "number", "number", "number", "number"], [this.handle, ptr, len, opacity, keyMode, chroma[0], chroma[1], chroma[2], similarity]));
  }

  /// Defines a screen-share source whose frame letterboxes to fit its cell.
  defineScreenShare(name: string): void {
    this.withName(name, (ptr, len) =>
      this.mod.ccall("goss_session_define_screen_share", "number", ["number", "number", "number"], [this.handle, ptr, len]));
  }

  /// Feeds a location fix for on-device geo.in_region membership; the location never leaves the engine.
  submitLocation(latitude: number, longitude: number, accuracyM: number, timestampUs: number): void {
    this.mod.ccall("goss_session_submit_location", "number", ["number", "number", "number", "number", "number"], [this.handle, latitude, longitude, accuracyM, timestampUs]);
  }

  /// Sets the geofence circle the app derives from a lens's intended place.
  setGeofence(latitude: number, longitude: number, radiusM: number): void {
    this.mod.ccall("goss_session_set_geofence", "number", ["number", "number", "number", "number"], [this.handle, latitude, longitude, radiusM]);
  }

  clearGeofence(): void {
    this.mod.ccall("goss_session_clear_geofence", "number", ["number"], [this.handle]);
  }

  /// Sets the geofence to an axis-aligned lat/lon box.
  setGeofenceBBox(minLat: number, minLon: number, maxLat: number, maxLon: number): void {
    this.mod.ccall("goss_session_set_geofence_bbox", "number", ["number", "number", "number", "number", "number"], [this.handle, minLat, minLon, maxLat, maxLon]);
  }

  /// Sets the geofence to a polygon ring of [latitude, longitude] pairs, three
  /// to 64 vertices.
  setGeofencePolygon(vertices: [number, number][]): void {
    const bytes = vertices.length * 2 * 8;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    const base = ptr >> 3;
    for (let i = 0; i < vertices.length; i += 1) {
      this.mod.HEAPF64[base + i * 2] = vertices[i]![0];
      this.mod.HEAPF64[base + i * 2 + 1] = vertices[i]![1];
    }
    this.mod.ccall("goss_session_set_geofence_polygon", "number", ["number", "number", "number"], [this.handle, ptr, vertices.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes]);
  }

  /// Sets the worst fix accuracy (meters) that still counts as inside a region;
  /// zero clears the gate.
  setGeoAccuracy(maxAccuracyM: number): void {
    this.mod.ccall("goss_session_set_geo_accuracy", "number", ["number", "number"], [this.handle, maxAccuracyM]);
  }

  /// Sets the color and half-width (normalized units) the next stroke opens with.
  setBrushStyle(r: number, g: number, b: number, a: number, width: number): void {
    this.mod.ccall("goss_session_brush_set_style", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, r, g, b, a, width]);
  }

  /// Opens a stroke in the current style. A fresh stroke drops the redo stack.
  beginStroke(): void {
    this.mod.ccall("goss_session_brush_begin", "number", ["number"], [this.handle]);
  }

  /// Adds a point to the open stroke, in normalized screen space (0..1).
  addStrokePoint(x: number, y: number): void {
    this.mod.ccall("goss_session_brush_point", "number", ["number", "number", "number"], [this.handle, x, y]);
  }

  /// Commits the open stroke. A stroke of fewer than two points is dropped.
  endStroke(): void {
    this.mod.ccall("goss_session_brush_end", "number", ["number"], [this.handle]);
  }

  undoStroke(): void {
    this.mod.ccall("goss_session_brush_undo", "number", ["number"], [this.handle]);
  }

  redoStroke(): void {
    this.mod.ccall("goss_session_brush_redo", "number", ["number"], [this.handle]);
  }

  clearStrokes(): void {
    this.mod.ccall("goss_session_brush_clear", "number", ["number"], [this.handle]);
  }

  /// The brush preset the next stroke opens with: 0 pen, 1 highlighter, 2 marker, 3 neon.
  setBrushMode(mode: number): void {
    this.mod.ccall("goss_session_brush_set_mode", "number", ["number", "number"], [this.handle, mode]);
  }

  /// Erases committed strokes within `radius` (normalized units) of the point
  /// and returns how many were removed.
  eraseStrokes(x: number, y: number, radius: number): number {
    const outPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]) as number;
    this.mod.ccall("goss_session_brush_erase_at", "number", ["number", "number", "number", "number", "number"], [this.handle, x, y, radius, outPtr]);
    const removed = this.mod.HEAP32[outPtr >> 2]!;
    this.mod.ccall("goss_free", null, ["number", "number"], [outPtr, 4]);
    return removed;
  }

  /// The world-anchored brush. Points are pushed in the world frame world
  /// tracking reports; the engine projects and draws them so a stroke stays
  /// fixed in the scene. Nothing draws without live world tracking.
  setARBrushStyle(r: number, g: number, b: number, a: number, width: number): void {
    this.mod.ccall("goss_session_ar_brush_set_style", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, r, g, b, a, width]);
  }

  setARBrushMode(mode: number): void {
    this.mod.ccall("goss_session_ar_brush_set_mode", "number", ["number", "number"], [this.handle, mode]);
  }

  beginARStroke(): void {
    this.mod.ccall("goss_session_ar_brush_begin", "number", ["number"], [this.handle]);
  }

  addARStrokePoint(x: number, y: number, z: number): void {
    this.mod.ccall("goss_session_ar_brush_point", "number", ["number", "number", "number", "number"], [this.handle, x, y, z]);
  }

  endARStroke(): void {
    this.mod.ccall("goss_session_ar_brush_end", "number", ["number"], [this.handle]);
  }

  undoARStroke(): void {
    this.mod.ccall("goss_session_ar_brush_undo", "number", ["number"], [this.handle]);
  }

  clearARStrokes(): void {
    this.mod.ccall("goss_session_ar_brush_clear", "number", ["number"], [this.handle]);
  }

  grab(x: number, y: number, z: number): void {
    this.mod.ccall("goss_session_grab", "number", ["number", "number", "number", "number"], [this.handle, x, y, z]);
  }

  release(): void {
    this.mod.ccall("goss_session_release", "number", ["number"], [this.handle]);
  }

  addCollider(x: number, y: number, z: number): void {
    this.mod.ccall("goss_session_add_collider", "number", ["number", "number", "number", "number"], [this.handle, x, y, z]);
  }

  eraseCollider(x: number, y: number, z: number, radius: number): void {
    this.mod.ccall("goss_session_erase_collider", "number", ["number", "number", "number", "number", "number"], [this.handle, x, y, z, radius]);
  }

  /// Releases one solver hair by the id the physics world assigned it,
  /// pairing the acquire a hair lens performs at activation, so a hair
  /// can retire mid-session without tearing the physics world down.
  /// False with no physics world or for an unknown id.
  physicsHairRemove(hairId: number): boolean {
    return this.mod.ccall("goss_physics_hair_remove", "number", ["number", "number"], [this.handle, hairId]) === 0;
  }

  /// Pulls the finished brush ribbon (x, y, r, g, b, a per vertex) for the
  /// renderer. Queries the float count, then reads it out of a scratch buffer.
  brushVertices(): Float32Array {
    const countPtr = this.mod.ccall("goss_alloc", "number", ["number"], [4]) as number;
    this.mod.ccall("goss_session_brush_vertices", "number", ["number", "number", "number", "number"], [this.handle, 0, 0, countPtr]);
    const count = this.mod.HEAP32[countPtr >> 2]!;
    if (count <= 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [countPtr, 4]);
      return new Float32Array(0);
    }
    const bytes = count * 4;
    const outPtr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    this.mod.ccall("goss_session_brush_vertices", "number", ["number", "number", "number", "number"], [this.handle, outPtr, count, countPtr]);
    const written = this.mod.HEAP32[countPtr >> 2]!;
    const out = new Float32Array(this.mod.HEAPF32.buffer, outPtr, written).slice();
    this.mod.ccall("goss_free", null, ["number", "number"], [outPtr, bytes]);
    this.mod.ccall("goss_free", null, ["number", "number"], [countPtr, 4]);
    return out;
  }

  setVideoFlip(enabled: boolean): void {
    this.videoFlipped = enabled;
  }

  isVideoFlipped(): boolean {
    return this.videoFlipped;
  }

  /// landmarks are raw tracker output - x, y in sourceWidth/sourceHeight
  /// pixels (whatever resolution the caller's own tracking pass ran
  /// at, which need not match the live video's own resolution), z in
  /// the same relative scale, three floats per point, matching
  /// goss_face_result's own convention. Scaled here to the frame
  /// currently being rendered - the engine's own contour math expects
  /// "frame pixels" of the frame it's compositing, not of whatever
  /// analysis resolution tracking happened to use. Null clears
  /// tracking (no face this frame).
  setFaceLandmarks(landmarks: Float32Array | null, sourceWidth: number, sourceHeight: number): void {
    if (!landmarks || landmarks.length === 0 || this.frameWidth === 0) {
      this.mod.ccall("goss_session_set_face_landmarks", "number", ["number", "number", "number"], [this.handle, 0, 0]);
      return;
    }
    const scaleX = this.frameWidth / sourceWidth;
    const scaleY = this.frameHeight / sourceHeight;
    const pointCount = landmarks.length / 3;
    const base = this.landmarksPtr >> 2;
    for (let at = 0; at < pointCount; at += 1) {
      this.mod.HEAPF32[base + at * 3] = landmarks[at * 3]! * scaleX;
      this.mod.HEAPF32[base + at * 3 + 1] = landmarks[at * 3 + 1]! * scaleY;
      this.mod.HEAPF32[base + at * 3 + 2] = landmarks[at * 3 + 2]!;
    }
    this.mod.ccall(
      "goss_session_set_face_landmarks",
      "number",
      ["number", "number", "number"],
      [this.handle, this.landmarksPtr, pointCount],
    );
  }

  /// Submits the faces tracked this frame for the multi-face path. landmarks
  /// are frame pixels, GOSS_FACE_LANDMARK_COUNT * 3 floats; presence defaults
  /// to 1. An empty array clears the path; faces past GOSS_FACE_MAX or below
  /// the tracked presence are dropped.
  submitFaces(faces: GossFaceInput[]): void {
    if (faces.length === 0) {
      this.mod.ccall("goss_session_submit_faces", "number", ["number", "number", "number"], [this.handle, 0, 0]);
      return;
    }
    const bytes = faces.length * FACE_RESULT_BYTES;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    const dv = new DataView(this.mod.HEAPU8.buffer, ptr, bytes);
    for (let i = 0; i < faces.length; i += 1) {
      const off = i * FACE_RESULT_BYTES;
      const base = ptr + off;
      const f = faces[i]!;
      const count = f.landmarks.length / 3;
      dv.setBigUint64(off, BigInt(f.frameSerial ?? 0), true);
      dv.setBigInt64(off + 8, BigInt(f.timestampUs ?? 0), true);
      dv.setFloat32(off + 16, f.presence ?? 1, true);
      dv.setUint32(off + 20, count, true);
      this.mod.HEAPF32.set(f.landmarks, (base + 24) >> 2);
      const bsStart = (base + 24 + GOSS_FACE_LANDMARK_COUNT * 3 * 4) >> 2;
      this.mod.HEAPF32.fill(0, bsStart, bsStart + GOSS_FACE_BLENDSHAPE_COUNT);
      if (f.blendshapes) this.mod.HEAPF32.set(f.blendshapes, bsStart);
    }
    this.mod.ccall("goss_session_submit_faces", "number", ["number", "number", "number"], [this.handle, ptr, faces.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes]);
  }

  /// The number of faces the last submitFaces kept, zero to GOSS_FACE_MAX.
  faceCount(): number {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [4]) as number;
    this.mod.ccall("goss_session_face_count", "number", ["number", "number"], [this.handle, ptr]);
    const count = this.mod.HEAP32[ptr >> 2]!;
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 4]);
    return count;
  }

  /// Reads the index-th submitted face, or null once index reaches faceCount,
  /// so a caller loops zero to faceCount to visit every face.
  faceResultAt(index: number): GossFaceOut | null {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [FACE_RESULT_BYTES]) as number;
    const status = this.mod.ccall("goss_session_face_result_at", "number", ["number", "number", "number"], [this.handle, index, ptr]) as number;
    if (status !== 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [ptr, FACE_RESULT_BYTES]);
      return null;
    }
    const dv = new DataView(this.mod.HEAPU8.buffer, ptr, FACE_RESULT_BYTES);
    const lmStart = (ptr + 24) >> 2;
    const bsStart = lmStart + GOSS_FACE_LANDMARK_COUNT * 3;
    const out: GossFaceOut = {
      frameSerial: dv.getBigUint64(0, true),
      timestampUs: dv.getBigInt64(8, true),
      presence: dv.getFloat32(16, true),
      landmarkCount: dv.getUint32(20, true),
      landmarks: this.mod.HEAPF32.slice(lmStart, bsStart),
      blendshapes: this.mod.HEAPF32.slice(bsStart, bsStart + GOSS_FACE_BLENDSHAPE_COUNT),
    };
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, FACE_RESULT_BYTES]);
    return out;
  }

  /// Submits the bodies tracked this frame for the multi-person path, so a
  /// lens can instance effects across every body. An empty array clears the
  /// path; bodies past GOSS_BODY_MAX are ignored.
  submitBodies(bodies: GossPoseInput[]): void {
    if (bodies.length === 0) {
      this.mod.ccall("goss_session_submit_bodies", "number", ["number", "number", "number"], [this.handle, 0, 0]);
      return;
    }
    const bytes = bodies.length * POSE_RESULT_BYTES;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    const dv = new DataView(this.mod.HEAPU8.buffer, ptr, bytes);
    for (let i = 0; i < bodies.length; i += 1) {
      const off = i * POSE_RESULT_BYTES;
      const base = ptr + off;
      const b = bodies[i]!;
      const count = b.landmarks.length / 3;
      dv.setBigUint64(off, BigInt(b.frameSerial ?? 0), true);
      dv.setBigInt64(off + 8, BigInt(b.timestampUs ?? 0), true);
      dv.setFloat32(off + 16, b.presence ?? 1, true);
      dv.setUint32(off + 20, count, true);
      this.mod.HEAPF32.set(b.landmarks, (base + 24) >> 2);
      const visStart = (base + 24 + GOSS_POSE_LANDMARK_COUNT * 3 * 4) >> 2;
      this.mod.HEAPF32.fill(0, visStart, visStart + GOSS_POSE_LANDMARK_COUNT * 2);
      if (b.visibilities) this.mod.HEAPF32.set(b.visibilities, visStart);
      if (b.presences) this.mod.HEAPF32.set(b.presences, visStart + GOSS_POSE_LANDMARK_COUNT);
    }
    this.mod.ccall("goss_session_submit_bodies", "number", ["number", "number", "number"], [this.handle, ptr, bodies.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes]);
  }

  /// Submits one frame's depth map from the host AR backend (WebXR depth-
  /// sensing): width by height metres per pixel, row major, with the near and
  /// far metres that bound it. An empty array clears it. Kept for depth
  /// occlusion against the rendered content.
  submitDepth(depth: Float32Array, width: number, height: number, near: number, far: number): void {
    if (depth.length === 0) {
      this.mod.ccall("goss_session_submit_depth", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, 0, 0, 0, 0, 0]);
      return;
    }
    const bytes = depth.length * 4;
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [bytes]) as number;
    this.mod.HEAPF32.set(depth, ptr >> 2);
    this.mod.ccall("goss_session_submit_depth", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, ptr, width, height, near, far]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, bytes]);
  }

  /// Segments a host-provided still image through the running segmenter: rgba
  /// is width by height RGBA8 pixels, row major. The mask reaches the active
  /// lens the way a camera frame's would.
  submitSegmentationImage(rgba: Uint8Array, width: number, height: number): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]) as number;
    this.mod.HEAPU8.set(rgba, ptr);
    this.mod.ccall("goss_session_submit_segmentation_image", "number", ["number", "number", "number", "number"], [this.handle, ptr, width, height]);
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, rgba.length]);
  }

  /// Samples a reference photo's makeup color per face part, so a tint.pass
  /// with a reference source paints the live face in that color. rgba is width
  /// by height RGBA8; landmarks is the reference face's 478 x, y, z points. An
  /// empty landmarks array clears the reference.
  setMakeupReference(rgba: Uint8Array, width: number, height: number, landmarks: Float32Array): void {
    if (landmarks.length === 0) {
      this.mod.ccall("goss_session_set_makeup_reference", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, 0, 0, 0, 0, 0]);
      return;
    }
    const rptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]) as number;
    this.mod.HEAPU8.set(rgba, rptr);
    const lbytes = landmarks.length * 4;
    const lptr = this.mod.ccall("goss_alloc", "number", ["number"], [lbytes]) as number;
    this.mod.HEAPF32.set(landmarks, lptr >> 2);
    this.mod.ccall("goss_session_set_makeup_reference", "number", ["number", "number", "number", "number", "number", "number"], [this.handle, rptr, width, height, lptr, landmarks.length / 3]);
    this.mod.ccall("goss_free", null, ["number", "number"], [rptr, rgba.length]);
    this.mod.ccall("goss_free", null, ["number", "number"], [lptr, lbytes]);
  }

  /// The number of bodies the last submitBodies kept, zero to GOSS_BODY_MAX.
  bodyCount(): number {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [4]) as number;
    this.mod.ccall("goss_session_body_count", "number", ["number", "number"], [this.handle, ptr]);
    const count = this.mod.HEAP32[ptr >> 2]!;
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 4]);
    return count;
  }

  /// Reads the index-th submitted body, or null once index reaches bodyCount,
  /// so a caller loops zero to bodyCount to visit every body.
  bodyResultAt(index: number): GossPoseOut | null {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [POSE_RESULT_BYTES]) as number;
    const status = this.mod.ccall("goss_session_body_result_at", "number", ["number", "number", "number"], [this.handle, index, ptr]) as number;
    if (status !== 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [ptr, POSE_RESULT_BYTES]);
      return null;
    }
    const dv = new DataView(this.mod.HEAPU8.buffer, ptr, POSE_RESULT_BYTES);
    const lmStart = (ptr + 24) >> 2;
    const visStart = lmStart + GOSS_POSE_LANDMARK_COUNT * 3;
    const presStart = visStart + GOSS_POSE_LANDMARK_COUNT;
    const out: GossPoseOut = {
      frameSerial: dv.getBigUint64(0, true),
      timestampUs: dv.getBigInt64(8, true),
      presence: dv.getFloat32(16, true),
      landmarkCount: dv.getUint32(20, true),
      landmarks: this.mod.HEAPF32.slice(lmStart, visStart),
      visibilities: this.mod.HEAPF32.slice(visStart, presStart),
      presences: this.mod.HEAPF32.slice(presStart, presStart + GOSS_POSE_LANDMARK_COUNT),
    };
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, POSE_RESULT_BYTES]);
    return out;
  }

  /// The tracked point (x, y in frame pixels, z in the same scale) of a named
  /// face region, or null until a face is tracked.
  faceRegion(region: GossFaceRegion): [number, number, number] | null {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const status = this.mod.ccall("goss_session_face_region", "number", ["number", "number", "number"], [this.handle, region, ptr]) as number;
    if (status !== 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
      return null;
    }
    const w = ptr >> 2;
    const out: [number, number, number] = [this.mod.HEAPF32[w], this.mod.HEAPF32[w + 1], this.mod.HEAPF32[w + 2]];
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
    return out;
  }

  /// The tracked point (x, y in frame pixels, z in the same scale) of a named
  /// body skeleton joint, or null until a body is tracked.
  bodyJoint(joint: GossBodyJoint): [number, number, number] | null {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const status = this.mod.ccall("goss_session_body_joint", "number", ["number", "number", "number"], [this.handle, joint, ptr]) as number;
    if (status !== 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
      return null;
    }
    const w = ptr >> 2;
    const out: [number, number, number] = [this.mod.HEAPF32[w], this.mod.HEAPF32[w + 1], this.mod.HEAPF32[w + 2]];
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
    return out;
  }

  /// The tracked point (x, y in frame pixels, z in the same scale) of a named
  /// joint on the handIndex-th tracked hand, or null until that hand is tracked.
  handJoint(joint: GossHandJoint, handIndex = 0): [number, number, number] | null {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [12]) as number;
    const status = this.mod.ccall("goss_session_hand_joint", "number", ["number", "number", "number", "number"], [this.handle, handIndex, joint, ptr]) as number;
    if (status !== 0) {
      this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
      return null;
    }
    const w = ptr >> 2;
    const out: [number, number, number] = [this.mod.HEAPF32[w], this.mod.HEAPF32[w + 1], this.mod.HEAPF32[w + 2]];
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, 12]);
    return out;
  }

  /// Feeds a segmentation mask (GOSS_SEGMENTATION_MASK_SIDE squared floats,
  /// from a GossSegmenter) into the session as the subject texture the blend
  /// and mask channels sample. Null clears it (no subject this frame).
  setSegmentationMask(mask: Float32Array | null): void {
    const count = GOSS_SEGMENTATION_MASK_SIDE * GOSS_SEGMENTATION_MASK_SIDE;
    if (!mask || mask.length < count) {
      this.mod.ccall("goss_session_set_segmentation_mask", "number", ["number", "number", "number"], [this.handle, 0, 0]);
      return;
    }
    this.mod.HEAPF32.set(mask.subarray(0, count), this.segmentationMaskPtr >> 2);
    this.mod.ccall(
      "goss_session_set_segmentation_mask",
      "number",
      ["number", "number", "number"],
      [this.handle, this.segmentationMaskPtr, count],
    );
  }

  /// The class channels the active lens samples, as a bitmask over
  /// GOSS_SEGMENTATION_CHANNELS. Upload exactly these with setSegmentationClassMask
  /// each frame; zero means only the subject mask is wanted.
  segmentationChannels(): number {
    return this.mod.ccall("goss_session_segmentation_channels", "number", ["number"], [this.handle]);
  }

  /// Feeds one class channel's mask (from a GossSegmenter's classMask) as the
  /// texture that channel's passes sample. channel indexes
  /// GOSS_SEGMENTATION_CHANNELS; channel 0 (person) goes through
  /// setSegmentationMask, which clears the classes, so upload these after.
  setSegmentationClassMask(channel: number, mask: Float32Array | null): void {
    const count = GOSS_SEGMENTATION_MASK_SIDE * GOSS_SEGMENTATION_MASK_SIDE;
    if (!mask || mask.length < count) {
      this.mod.ccall("goss_session_set_segmentation_class_mask", "number", ["number", "number", "number", "number"], [this.handle, channel, 0, 0]);
      return;
    }
    this.mod.HEAPF32.set(mask.subarray(0, count), this.segmentationMaskPtr >> 2);
    this.mod.ccall(
      "goss_session_set_segmentation_class_mask",
      "number",
      ["number", "number", "number", "number"],
      [this.handle, channel, this.segmentationMaskPtr, count],
    );
  }

  /// Uploads one of whiten's four lookup textures directly - slot 0
  /// gray, 1 origin, 2 skin, 3 custom. loadWhitenLuts is the sugar most
  /// callers want; this is the raw upload it calls internally.
  setBeautyLut(slot: number, rgba: Uint8ClampedArray | Uint8Array, width: number, height: number): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]);
    this.mod.HEAPU8.set(rgba, ptr);
    this.mod.ccall(
      "goss_session_set_beauty_lut",
      "number",
      ["number", "number", "number", "number", "number"],
      [this.handle, slot, ptr, width, height],
    );
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, rgba.length]);
  }

  /// Uploads lipstick's or blush's own source image directly.
  /// loadMakeupTextures is the sugar most callers want; this is the raw
  /// upload it calls internally.
  setBeautyMakeupTexture(effect: GossBeautyEffect, rgba: Uint8ClampedArray | Uint8Array, width: number, height: number): void {
    const ptr = this.mod.ccall("goss_alloc", "number", ["number"], [rgba.length]);
    this.mod.HEAPU8.set(rgba, ptr);
    this.mod.ccall(
      "goss_session_set_beauty_makeup_texture",
      "number",
      ["number", "number", "number", "number", "number"],
      [this.handle, effect, ptr, width, height],
    );
    this.mod.ccall("goss_free", null, ["number", "number"], [ptr, rgba.length]);
  }

  /// Fetches the four whiten lookup textures (gray/origin/skin/custom),
  /// relative to lutBaseUrl. Safe to call once after construction;
  /// setWhiten stays a no-op until this resolves.
  async loadWhitenLuts(lutBaseUrl: string | URL): Promise<void> {
    const names = ["lookup_gray", "lookup_origin", "lookup_skin", "lookup_light"];
    const images = await Promise.all(
      names.map((name) => fetch(new URL(`${name}.png`, lutBaseUrl)).then((r) => r.blob()).then(decodeImageRgba)),
    );
    images.forEach((image, slot) => {
      this.setBeautyLut(slot, image.data, image.width, image.height);
      this.whitenLutsLoaded += 1;
    });
  }

  /// Fetches mouth.png/blusher.png, relative to baseUrl. Safe to call
  /// once after construction; setLipstick/setBlush stay a no-op until
  /// this resolves.
  async loadMakeupTextures(baseUrl: string | URL): Promise<void> {
    const [mouth, blusher] = await Promise.all(
      ["mouth.png", "blusher.png"].map((name) => fetch(new URL(name, baseUrl)).then((r) => r.blob()).then(decodeImageRgba)),
    );
    for (const [effect, image] of [
      [GossBeautyEffect.Lipstick, mouth],
      [GossBeautyEffect.Blush, blusher],
    ] as const) {
      this.setBeautyMakeupTexture(effect, image.data, image.width, image.height);
    }
    this.lipstickTextureLoaded = true;
    this.blushTextureLoaded = true;
  }

  private ensureFramePixels(byteLength: number): void {
    if (this.framePixelsCapacity >= byteLength) return;
    if (this.framePixelsPtr !== 0) this.mod.ccall("goss_free", null, ["number", "number"], [this.framePixelsPtr, this.framePixelsCapacity]);
    this.framePixelsPtr = this.mod.ccall("goss_alloc", "number", ["number"], [byteLength]);
    this.framePixelsCapacity = byteLength;
  }

  /// rotationDegrees omitted means the setVideoFlip state decides (a
  /// flipped source is a 180-degree turn); timestampUs omitted means
  /// now.
  submitFrameRgbaCopy(rgba: Uint8ClampedArray | Uint8Array, stride: number, width: number, height: number, pixelFormat: GossPixelFormat = GossPixelFormat.Rgba8, rotationDegrees?: number, mirrored = false, timestampUs?: number): void {
    this.frameWidth = width;
    this.frameHeight = height;
    const byteLength = stride * height;
    this.ensureFramePixels(byteLength);
    this.mod.HEAPU8.set(rgba.subarray(0, byteLength), this.framePixelsPtr);

    const rotationQuarters = ((rotationDegrees ?? (this.videoFlipped ? 180 : 0)) / 90) & 3;
    const flags = (mirrored ? FRAME_FLAG_MIRROR : 0) | (rotationQuarters << FRAME_ROTATION_SHIFT);
    this.mod.setValue(this.frameDescPtr, width, "i32");
    this.mod.setValue(this.frameDescPtr + 4, height, "i32");
    this.mod.setValue(this.frameDescPtr + 8, pixelFormat, "i32");
    this.mod.setValue(this.frameDescPtr + 12, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 16, 0, "i32");
    this.mod.setValue(this.frameDescPtr + 20, flags, "i32");
    const stampUs = timestampUs ?? Math.round(performance.now() * 1000);
    this.mod.setValue(this.frameDescPtr + 24, stampUs >>> 0, "i32");
    this.mod.setValue(this.frameDescPtr + 28, Math.floor(stampUs / 4294967296), "i32");

    this.mod.ccall(
      "goss_session_submit_frame_rgba_copy",
      "number",
      ["number", "number", "number", "number"],
      [this.handle, this.frameDescPtr, this.framePixelsPtr, stride],
    );
  }

  /// Feeds the platform's world understanding into the session: camera
  /// pose and projection (column-major float16 arrays), tracked planes,
  /// anchors, and the light estimate. Drives the world.tracking_state
  /// trigger and world-anchored lens content.
  submitWorld(state: GossWorldState, planes: GossWorldPlane[] = [], anchors: GossWorldAnchorInput[] = [], light?: GossWorldLight): void {
    const stateBytes = 144;
    const planeBytes = 88;
    const anchorBytes = 72;
    const lightBytes = 8;
    const total = stateBytes + planes.length * planeBytes + anchors.length * anchorBytes + lightBytes;
    this.ensureWorldScratch(total);
    const base = this.worldScratchPtr;
    const heap = this.mod.HEAPU8;
    const view = new DataView(heap.buffer, base, total);

    view.setUint32(0, state.trackingState, true);
    for (let i = 0; i < 16; i++) view.setFloat32(4 + i * 4, state.worldFromCamera[i], true);
    for (let i = 0; i < 16; i++) view.setFloat32(68 + i * 4, state.projection[i], true);
    view.setBigInt64(136, BigInt(Math.round(state.timestampUs)), true);

    let at = stateBytes;
    const planesPtr = planes.length > 0 ? base + at : 0;
    for (const plane of planes) {
      view.setBigUint64(at, BigInt(plane.id), true);
      for (let i = 0; i < 16; i++) view.setFloat32(at + 8 + i * 4, plane.pose[i], true);
      view.setFloat32(at + 72, plane.extentX, true);
      view.setFloat32(at + 76, plane.extentZ, true);
      view.setUint32(at + 80, plane.classification, true);
      at += planeBytes;
    }
    const anchorsPtr = anchors.length > 0 ? base + at : 0;
    for (const anchorInput of anchors) {
      view.setBigUint64(at, BigInt(anchorInput.id), true);
      for (let i = 0; i < 16; i++) view.setFloat32(at + 8 + i * 4, anchorInput.pose[i], true);
      at += anchorBytes;
    }
    let lightPtr = 0;
    if (light) {
      lightPtr = base + at;
      view.setFloat32(at, light.ambientIntensity, true);
      view.setFloat32(at + 4, light.colorTemperatureKelvin, true);
    }

    this.mod.ccall(
      "goss_session_submit_world",
      "number",
      ["number", "number", "number", "number", "number", "number", "number"],
      [this.handle, base, planesPtr, planes.length, anchorsPtr, anchors.length, lightPtr],
    );
  }

  private ensureWorldScratch(byteLength: number): void {
    if (this.worldScratchLen >= byteLength) return;
    if (this.worldScratchPtr !== 0) this.mod.ccall("goss_free", null, ["number", "number"], [this.worldScratchPtr, this.worldScratchLen]);
    this.worldScratchPtr = this.mod.ccall("goss_alloc", "number", ["number"], [byteLength]);
    this.worldScratchLen = byteLength;
  }

  /// Reports one finished frame: measured whole-pipeline time plus
  /// thermal pressure (nominal by default - no browser API surfaces
  /// device thermal state). Returns the degradation level in effect
  /// for the next frame.
  reportFrame(frameTimeUs: number, thermal: GossThermal = GossThermal.Nominal): GossDegradeLevel {
    return this.mod.ccall("goss_session_report_frame", "number", ["number", "number", "number"], [this.handle, frameTimeUs, thermal]);
  }

  degradeLevel(): GossDegradeLevel {
    return this.mod.ccall("goss_session_degrade_level", "number", ["number"], [this.handle]);
  }

  destroy(): void {
    this.mod.ccall("goss_session_destroy", null, ["number"], [this.handle]);
  }
}

/// The SDK-facing orchestrator: capture loop, video element, DOM
/// events. Composes Gosslens/GossEngine/GossSession rather than being one of
/// them - the same relationship CameraController/PreviewViewController
/// have to GossEngine/GossSession on iOS, not a fourth ABI-shaped type.
export class GossPreviewSession {
  readonly video = document.createElement("video");
  state: GossCaptureState = "idle";

  private stream: MediaStream | null = null;
  private raf = 0;
  private lastTick = 0;
  private fpsWindowStart = 0;
  private fpsWindowFrames = 0;
  private renderedFrames = 0;
  private cameraFrames = 0;
  private lastVideoTime = -1;
  private scratchCanvas = document.createElement("canvas");
  private scratchCtx: CanvasRenderingContext2D;

  private constructor(
    readonly gosslens: Gosslens,
    readonly engine: GossEngine,
    readonly session: GossSession,
    private events: GossSessionEvents,
  ) {
    this.scratchCtx = this.scratchCanvas.getContext("2d", { willReadFrequently: true })!;
  }

  static async create(canvas: HTMLCanvasElement, wasmJsUrl: string | URL, events: GossSessionEvents = {}): Promise<GossPreviewSession> {
    const gosslens = await Gosslens.load(canvas, wasmJsUrl);
    const engine = GossEngine.create(gosslens);
    await engine.initRenderer(canvas);
    const session = GossSession.create(engine);
    return new GossPreviewSession(gosslens, engine, session, events);
  }

  abiVersion(): number {
    return this.gosslens.abiVersion();
  }

  private setState(state: GossCaptureState): void {
    this.state = state;
    this.events.onState?.(state);
  }

  setWhiten(amount: number): void {
    this.session.setWhiten(amount);
  }

  setSmooth(amount: number): void {
    this.session.setSmooth(amount);
  }

  setThinFace(amount: number): void {
    this.session.setThinFace(amount);
  }

  setBigEye(amount: number): void {
    this.session.setBigEye(amount);
  }

  setLipstick(amount: number): void {
    this.session.setLipstick(amount);
  }

  setBlush(amount: number): void {
    this.session.setBlush(amount);
  }

  activateLens(manifestJson: string): void {
    this.session.activateLens(manifestJson);
  }

  deactivateLens(): void {
    this.session.deactivateLens();
  }

  tickLens(dtUs: number, signals: GossLensSignals = {}): void {
    this.session.tickLens(dtUs, signals);
  }

  setVideoFlip(enabled: boolean): void {
    this.session.setVideoFlip(enabled);
  }

  isVideoFlipped(): boolean {
    return this.session.isVideoFlipped();
  }

  setFaceLandmarks(landmarks: Float32Array | null, sourceWidth: number, sourceHeight: number): void {
    this.session.setFaceLandmarks(landmarks, sourceWidth, sourceHeight);
  }

  loadWhitenLuts(lutBaseUrl: string | URL): Promise<void> {
    return this.session.loadWhitenLuts(lutBaseUrl);
  }

  loadMakeupTextures(baseUrl: string | URL): Promise<void> {
    return this.session.loadMakeupTextures(baseUrl);
  }

  /// Uploads a still image directly into the frame the engine renders,
  /// bypassing the video element - freezeCamera() first stops tick()
  /// from re-submitting over it. Test/demo tooling only: skin-smoothing's
  /// content-adaptive blend needs a real face to prove, not a fake one.
  async loadStillFrame(url: string): Promise<void> {
    const image = await decodeImageRgba(await (await fetch(url)).blob(), {
      maxWidth: this.scratchCanvas.width,
      maxHeight: this.scratchCanvas.height,
    });
    // Not mirrored: a loaded test photo isn't a front camera, and
    // setLandmarksFromStill tracks this same unmirrored image - mirroring
    // only the background here would leave the tracked landmarks
    // pointing at the wrong side of the now-mirrored face.
    this.session.submitFrameRgbaCopy(image.data, image.width * 4, image.width, image.height);
  }

  async start(): Promise<void> {
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      this.setState(err instanceof DOMException && err.name === "NotAllowedError" ? "denied" : "failed");
      return;
    }
    const track = this.stream.getVideoTracks()[0];
    track.addEventListener("mute", () => this.setState("interrupted"));
    track.addEventListener("unmute", () => this.setState("running"));
    track.addEventListener("ended", () => this.setState("failed"));

    this.video.srcObject = this.stream;
    this.video.muted = true;
    this.video.playsInline = true;
    await this.video.play();
    this.setState("running");
    this.fpsWindowStart = performance.now();
    this.lastTick = performance.now();
    this.tick();
  }

  stop(): void {
    cancelAnimationFrame(this.raf);
    this.stream?.getTracks().forEach((track) => track.stop());
    this.stream = null;
    this.setState("idle");
  }

  private tick = (): void => {
    this.raf = requestAnimationFrame(this.tick);
    if (this.engine.isCaptureInFlight) return;
    const now = performance.now();
    const frameTimeUs = Math.max(0, Math.round((now - this.lastTick) * 1000));
    this.lastTick = now;
    this.session.reportFrame(frameTimeUs);

    if (this.video.readyState >= 2 && this.video.currentTime !== this.lastVideoTime) {
      this.lastVideoTime = this.video.currentTime;
      this.cameraFrames += 1;
      const width = this.video.videoWidth;
      const height = this.video.videoHeight;
      this.scratchCanvas.width = width;
      this.scratchCanvas.height = height;
      this.scratchCtx.drawImage(this.video, 0, 0, width, height);
      const pixels = this.scratchCtx.getImageData(0, 0, width, height);
      // Not mirrored here - the demo page's own CSS mirrors the canvas
      // for display, so the engine keeps working in the camera's real,
      // unmirrored coordinate space (matching tracking, which analyzes
      // this same unmirrored buffer).
      this.session.submitFrameRgbaCopy(pixels.data, width * 4, width, height);
    }

    const status = this.engine.renderFrame(this.session);
    if (status === GOSS_OK) {
      this.renderedFrames += 1;
      this.fpsWindowFrames += 1;
    }

    if (now - this.fpsWindowStart >= 1000) {
      const fps = (this.fpsWindowFrames * 1000) / (now - this.fpsWindowStart);
      this.events.onFps?.(fps, this.renderedFrames, this.cameraFrames);
      this.fpsWindowStart = now;
      this.fpsWindowFrames = 0;
    }
  };

  degradeLevel(): GossDegradeLevel {
    return this.session.degradeLevel();
  }

  captureFrame(): Promise<string> {
    return this.engine.captureFrame(this.session);
  }

  readCenterPixel(): Promise<Uint8Array> {
    return this.engine.readCenterPixel(this.session);
  }

  readFrameSum(): Promise<number> {
    return this.engine.readFrameSum(this.session);
  }
}

export { GossWebXRWorldSource } from "./world";
export type { GossXRFrameLike } from "./world";
