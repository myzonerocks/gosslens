package com.gosslens

import android.os.Build
import android.view.Surface
import java.lang.ref.Cleaner
import java.nio.ByteBuffer
import java.nio.ByteOrder

// The Kotlin face of the goss_ ABI. The native names mirror the C surface one
// to one and carry no logic; GossSession and GossEngine below are the idiomatic
// wrappers the app consumes.
object Gosslens {
    init {
        System.loadLibrary("gosslens")
    }

    internal external fun nativeAbiVersion(): Int
    internal external fun nativeEngineCreate(texturePoolCapacity: Int, stagingPoolCapacity: Int): Long
    internal external fun nativeEngineDestroy(engine: Long)
    internal external fun nativeInitRenderer(engine: Long, surface: Surface, width: Int, height: Int): Int
    internal external fun nativeResize(engine: Long, width: Int, height: Int)
    internal external fun nativeRequestScreenshot(engine: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    internal external fun nativeCapturePhoto(engine: Long, session: Long, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeCaptureLiveFrame(engine: Long, session: Long, format: Int, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeCaptureStill(engine: Long, session: Long, width: Int, height: Int, supersample: Int, format: Int, quality: Int, colorSpace: Int, bitDepth: Int, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeRecordingStart(engine: Long, session: Long, pathBuffer: ByteBuffer, pathLen: Int, width: Int, height: Int, bitrate: Int, codec: Int): Int
    internal external fun nativeRecordingStop(engine: Long): Int
    internal external fun nativeSubmitWorld(session: Long, stateBuffer: ByteBuffer, planesBuffer: ByteBuffer, planeCount: Int, anchorsBuffer: ByteBuffer, anchorCount: Int, lightBuffer: ByteBuffer): Int
    internal external fun nativeSubmitAudio(session: Long, samplesBuffer: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int, timestampUs: Long): Int
    internal external fun nativeRenderFrame(engine: Long, session: Long): Int
    internal external fun nativeCompilePrompt(engine: Long, promptBuffer: ByteBuffer, promptLen: Int, outBuffer: ByteBuffer, outCapacity: Long, lenBuffer: ByteBuffer): Int
    internal external fun nativeSessionCreate(engine: Long, frameBudgetUs: Int): Long
    internal external fun nativeSessionDestroy(session: Long)
    internal external fun nativeSubmitFrameCopy(
        session: Long,
        yBuffer: ByteBuffer,
        yStride: Int,
        uvBuffer: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        flags: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeReportFrame(session: Long, frameTimeUs: Int, thermal: Int): Int
    internal external fun nativeEnableFaceTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisableFaceTracking(session: Long)
    internal external fun nativeEnableHandTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisableHandTracking(session: Long)
    internal external fun nativeHandResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeEnablePoseTracking(session: Long, taskBuffer: ByteBuffer, taskLen: Int, threads: Int): Int
    internal external fun nativeDisablePoseTracking(session: Long)
    internal external fun nativeSetPoseUpperBody(session: Long, enabled: Int): Int
    internal external fun nativePoseResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeFacePose(session: Long, matrixBuffer: ByteBuffer): Int
    internal external fun nativeFaceRegion(session: Long, region: Int, outBuffer: ByteBuffer): Int
    internal external fun nativeBodyJoint(session: Long, joint: Int, outBuffer: ByteBuffer): Int
    internal external fun nativeHandJoint(session: Long, handIndex: Int, joint: Int, outBuffer: ByteBuffer): Int
    internal external fun nativeTrackFrame(
        session: Long,
        yBuffer: ByteBuffer,
        yStride: Int,
        uvBuffer: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeSubmitAvatarSource(
        session: Long,
        yBuffer: ByteBuffer,
        yStride: Int,
        uvBuffer: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeFaceResult(session: Long, resultBuffer: ByteBuffer): Int
    internal external fun nativeSubmitFaces(session: Long, faces: ByteBuffer, count: Int): Int
    internal external fun nativeFaceCount(session: Long): Int
    internal external fun nativeFaceResultAt(session: Long, index: Int, resultBuffer: ByteBuffer): Int
    internal external fun nativeSubmitBodies(session: Long, bodies: ByteBuffer, count: Int): Int
    internal external fun nativeSubmitDepth(session: Long, depth: ByteBuffer, width: Int, height: Int, near: Float, far: Float): Int
    internal external fun nativeSubmitSegmentationImage(session: Long, rgba: ByteBuffer, width: Int, height: Int): Int
    internal external fun nativeSetMakeupReference(session: Long, rgba: ByteBuffer, width: Int, height: Int, landmarks: ByteBuffer, count: Int): Int
    internal external fun nativeBodyCount(session: Long): Int
    internal external fun nativeBodyResultAt(session: Long, index: Int, resultBuffer: ByteBuffer): Int
    internal external fun nativeEnableBeauty(session: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    internal external fun nativeDisableBeauty(session: Long)
    internal external fun nativeSetBeauty(session: Long, effect: Int, value: Float): Int
    internal external fun nativeBeautifyFrame(session: Long, rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Int
    internal external fun nativeActivateLens(session: Long, manifestBuffer: ByteBuffer, manifestLen: Int): Int
    internal external fun nativeDeactivateLens(session: Long)
    internal external fun nativeTickLens(session: Long, dtUs: Int, signalsBuffer: ByteBuffer): Int
    internal external fun nativeParameterValue(session: Long, nameBuffer: ByteBuffer, nameLen: Int, outBuffer: ByteBuffer): Int
    internal external fun nativePullAudio(session: Long, outBuffer: ByteBuffer, frames: Int): Int
    internal external fun nativeMixOutputAudio(session: Long, micBuffer: ByteBuffer?, outBuffer: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int): Int
    internal external fun nativeSetCameraControls(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeCameraControls(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeSetRecordingPolicy(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeRecordingPolicy(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeSetCaptureUi(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeCaptureUi(session: Long, buffer: ByteBuffer): Int
    internal external fun nativeFireEvent(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeDefineSource(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeRemoveSource(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeSubmitSourceFrameRgba(session: Long, nameBuffer: ByteBuffer, nameLen: Int, rgbaBuffer: ByteBuffer, width: Int, height: Int, stride: Int, pixelFormat: Int): Int
    internal external fun nativeSetLayout(session: Long, arrangement: Int): Int
    internal external fun nativeClearLayout(session: Long): Int
    internal external fun nativeSetSourceComposite(session: Long, nameBuffer: ByteBuffer, nameLen: Int, opacity: Float, keyMode: Int, keyR: Float, keyG: Float, keyB: Float, similarity: Float): Int
    internal external fun nativeDefineScreenShare(session: Long, nameBuffer: ByteBuffer, nameLen: Int): Int
    internal external fun nativeSubmitLocation(session: Long, latitude: Double, longitude: Double, accuracyM: Float, timestampUs: Long): Int
    internal external fun nativeSetGeofence(session: Long, latitude: Double, longitude: Double, radiusM: Double): Int
    internal external fun nativeClearGeofence(session: Long): Int
    internal external fun nativeSetGeofenceBbox(session: Long, minLat: Double, minLon: Double, maxLat: Double, maxLon: Double): Int
    internal external fun nativeSetGeofencePolygon(session: Long, coordsBuffer: ByteBuffer, vertexCount: Int): Int
    internal external fun nativeSetGeoAccuracy(session: Long, maxAccuracyM: Float): Int
    internal external fun nativeBrushSetStyle(session: Long, r: Float, g: Float, b: Float, a: Float, width: Float): Int
    internal external fun nativeBrushBegin(session: Long): Int
    internal external fun nativeBrushPoint(session: Long, x: Float, y: Float): Int
    internal external fun nativeBrushEnd(session: Long): Int
    internal external fun nativeBrushUndo(session: Long): Int
    internal external fun nativeBrushRedo(session: Long): Int
    internal external fun nativeBrushClear(session: Long): Int
    internal external fun nativeBrushVertexCount(session: Long): Int
    internal external fun nativeBrushVertices(session: Long, outBuffer: ByteBuffer, capacityFloats: Int): Int
    internal external fun nativeBrushSetMode(session: Long, mode: Int): Int
    internal external fun nativeBrushEraseAt(session: Long, x: Float, y: Float, radius: Float): Int
    internal external fun nativeArBrushSetStyle(session: Long, r: Float, g: Float, b: Float, a: Float, width: Float): Int
    internal external fun nativeArBrushSetMode(session: Long, mode: Int): Int
    internal external fun nativeArBrushBegin(session: Long): Int
    internal external fun nativeArBrushPoint(session: Long, x: Float, y: Float, z: Float): Int
    internal external fun nativeArBrushEnd(session: Long): Int
    internal external fun nativeArBrushUndo(session: Long): Int
    internal external fun nativeArBrushClear(session: Long): Int
    internal external fun nativeGrab(session: Long, x: Float, y: Float, z: Float): Int
    internal external fun nativeTouch(session: Long, phase: Int, pointerId: Int, x: Float, y: Float): Int
    internal external fun nativePullHaptic(session: Long, outBuffer: ByteBuffer): Int
    internal external fun nativeRelease(session: Long): Int
    internal external fun nativeAddCollider(session: Long, x: Float, y: Float, z: Float): Int
    internal external fun nativeEraseCollider(session: Long, x: Float, y: Float, z: Float, radius: Float): Int
    internal external fun nativeSubmitHardwareBuffer(
        session: Long,
        hardwareBuffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        flags: Int,
        colorStandard: Int,
        colorRange: Int,
        timestampUs: Long,
    ): Int
    internal external fun nativeDegradeLevel(session: Long): Int
    internal external fun nativeYuvToRgb(standard: Int, range: Int, outBuffer: ByteBuffer): Int
    internal external fun nativeSolveTwoBoneIk(inBuffer: ByteBuffer, upperLen: Float, lowerLen: Float, outBuffer: ByteBuffer): Int
    internal external fun nativeActivateLensFromDirectory(session: Long, pathBuffer: ByteBuffer, pathLen: Int): Int
    internal external fun nativeSubmitFrame(session: Long, plane0: Long, plane1: Long, plane2: Long, planeCount: Int, width: Int, height: Int, pixelFormat: Int, flags: Int, colorStandard: Int, colorRange: Int, timestampUs: Long): Int
    internal external fun nativeSubmitFrameRgbaCopy(session: Long, rgba: ByteBuffer, stride: Int, width: Int, height: Int, pixelFormat: Int, flags: Int, timestampUs: Long): Int
    internal external fun nativeEnableSegmentation(session: Long, modelBuffer: ByteBuffer, modelLen: Int, threads: Int): Int
    internal external fun nativeDisableSegmentation(session: Long)
    internal external fun nativeSetFaceLandmarks(session: Long, pointsBuffer: ByteBuffer, pointCount: Int): Int
    internal external fun nativeSetBeautyLut(session: Long, slot: Int, rgbaBuffer: ByteBuffer, width: Int, height: Int): Int
    internal external fun nativeSetBeautyMakeupTexture(session: Long, effect: Int, rgbaBuffer: ByteBuffer, width: Int, height: Int): Int
    internal external fun nativeCaptureFrame(engine: Long, session: Long, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeCapturePhotoAs(engine: Long, session: Long, format: Int, quality: Int, dataBuffer: ByteBuffer, dataCapacity: Long, infoBuffer: ByteBuffer): Int
    internal external fun nativeRenderToLiveTexture(engine: Long, session: Long, nativeHandle: Long, width: Int, height: Int): Int
    internal external fun nativeReleaseLiveTexture(engine: Long, nativeHandle: Long): Int
    internal external fun nativePhysicsHairRemove(session: Long, hairId: Int): Int

    const val COLOR_BT601 = 0
    const val COLOR_BT709 = 1
    const val COLOR_BT2020 = 2
    const val RANGE_VIDEO = 0
    const val RANGE_FULL = 1
    const val PIXEL_NV12 = 0
    const val PIXEL_NV21 = 1
    const val PIXEL_I420 = 2
    const val PIXEL_BGRA8 = 3
    const val PIXEL_RGBA8 = 4
    const val FLAG_MIRROR = 1
    const val ROTATION_SHIFT = 8
    const val FACE_LANDMARK_COUNT = 478
    const val FACE_BLENDSHAPE_COUNT = 52
    const val FACE_RESULT_BYTES = 5968
    const val FACE_MAX = 4
    const val BODY_MAX = 4

    // Named face-mesh attach points for faceRegion; left/right are the subject's.
    const val FACE_REGION_FOREHEAD = 0
    const val FACE_REGION_GLABELLA = 1
    const val FACE_REGION_NOSE_TIP = 2
    const val FACE_REGION_CHIN = 3
    const val FACE_REGION_LEFT_EYE = 4
    const val FACE_REGION_RIGHT_EYE = 5
    const val FACE_REGION_LEFT_CHEEK = 6
    const val FACE_REGION_RIGHT_CHEEK = 7
    const val FACE_REGION_LEFT_EAR = 8
    const val FACE_REGION_RIGHT_EAR = 9
    const val FACE_REGION_MOUTH_CENTER = 10
    const val FACE_REGION_LEFT_MOUTH_CORNER = 11
    const val FACE_REGION_RIGHT_MOUTH_CORNER = 12

    // Named attach points on the tracked body skeleton for bodyJoint.
    const val BODY_JOINT_HEAD = 0
    const val BODY_JOINT_LEFT_SHOULDER = 1
    const val BODY_JOINT_RIGHT_SHOULDER = 2
    const val BODY_JOINT_LEFT_ELBOW = 3
    const val BODY_JOINT_RIGHT_ELBOW = 4
    const val BODY_JOINT_LEFT_WRIST = 5
    const val BODY_JOINT_RIGHT_WRIST = 6
    const val BODY_JOINT_LEFT_HIP = 7
    const val BODY_JOINT_RIGHT_HIP = 8
    const val BODY_JOINT_LEFT_KNEE = 9
    const val BODY_JOINT_RIGHT_KNEE = 10
    const val BODY_JOINT_LEFT_ANKLE = 11
    const val BODY_JOINT_RIGHT_ANKLE = 12
    // Named attach points on a tracked hand for handJoint; palm is the knuckle.
    const val HAND_JOINT_WRIST = 0
    const val HAND_JOINT_THUMB_TIP = 1
    const val HAND_JOINT_INDEX_TIP = 2
    const val HAND_JOINT_MIDDLE_TIP = 3
    const val HAND_JOINT_RING_TIP = 4
    const val HAND_JOINT_PINKY_TIP = 5
    const val HAND_JOINT_PALM = 6
    const val HAND_LANDMARK_COUNT = 21
    const val HAND_MAX = 2
    const val HAND_RESULT_BYTES = 560
    const val POSE_LANDMARK_COUNT = 33
    const val POSE_RESULT_BYTES = 688
    const val GESTURE_NONE = 0
    const val GESTURE_CLOSED_FIST = 1
    const val GESTURE_OPEN_PALM = 2
    const val GESTURE_POINTING_UP = 3
    const val GESTURE_THUMB_DOWN = 4
    const val GESTURE_THUMB_UP = 5
    const val GESTURE_VICTORY = 6
    const val GESTURE_ILOVEYOU = 7
    const val LENS_SIGNALS_BYTES = 232
    const val STATUS_AGAIN = 7

    fun abiVersion(): Int = nativeAbiVersion()

    /** The 4x4 YUV-to-RGB conversion matrix for a color standard and
     * range, column-major, sixteen floats. */
    fun yuvToRgb(colorStandard: Int, colorRange: Int): FloatArray {
        val buffer = ByteBuffer.allocateDirect(16 * 4).order(java.nio.ByteOrder.nativeOrder())
        check(nativeYuvToRgb(colorStandard, colorRange, buffer) == 0) { "unknown color standard or range" }
        val matrix = FloatArray(16)
        buffer.asFloatBuffer().get(matrix)
        return matrix
    }

    /** Analytic two-bone inverse kinematics for a limb: root, the upper and
     * lower bone lengths, target, and pole (each xyz); returns the mid joint
     * then the end. An out-of-reach target extends the limb straight at it. */
    fun solveTwoBoneIk(root: FloatArray, upperLen: Float, lowerLen: Float, target: FloatArray, pole: FloatArray): Pair<FloatArray, FloatArray> {
        val inBuf = ByteBuffer.allocateDirect(9 * 4).order(java.nio.ByteOrder.nativeOrder())
        inBuf.asFloatBuffer().apply { put(root); put(target); put(pole) }
        val outBuf = ByteBuffer.allocateDirect(6 * 4).order(java.nio.ByteOrder.nativeOrder())
        check(nativeSolveTwoBoneIk(inBuf, upperLen, lowerLen, outBuf) == 0) { "invalid ik arguments" }
        val out = FloatArray(6)
        outBuf.asFloatBuffer().get(out)
        return Pair(out.copyOfRange(0, 3), out.copyOfRange(3, 6))
    }

    fun flagsFor(rotationDegrees: Int, mirrored: Boolean): Int {
        val quarterTurns = ((rotationDegrees % 360) / 90) and 0x3
        var flags = quarterTurns shl ROTATION_SHIFT
        if (mirrored) flags = flags or FLAG_MIRROR
        return flags
    }
}

/** Pool capacities for the engine's texture and staging pools; the
 * core clamps and defaults exactly as the C config does. */
data class GossEngineConfig(val texturePoolCapacity: Int, val stagingPoolCapacity: Int)

/** frameBudgetUs is the whole-pipeline frame time the degradation
 * policy holds the session to; zero means the built-in 30 fps budget. */
data class GossSessionConfig(val frameBudgetUs: Int)

/** Declarative camera-hardware intent. The engine normalizes every field; the
 * app reads it back and drives CameraX. Modes: flash 0 off/1 on/2 auto; focus
 * 0 auto/1 locked/2 point; exposure 0 auto/1 locked. Points are normalized. */
data class GossCameraControls(
    val flashMode: Int = 0,
    val torch: Int = 0,
    val focusMode: Int = 0,
    val exposureMode: Int = 0,
    val focusPointX: Float = 0.5f,
    val focusPointY: Float = 0.5f,
    val exposureLinked: Int = 1,
    val exposurePointX: Float = 0.5f,
    val exposurePointY: Float = 0.5f,
    val exposureBiasEv: Float = 0f,
    val zoomFactor: Float = 1f,
    val maxZoomFactor: Float = 0f,
    val mirrorSavePolicy: Int = 0,
)

data class GossRecordingPolicy(
    val maxDurationMs: Int = 0,
    val minClipMs: Int = 0,
    val segmentMode: Int = 0,
    val loopPlayback: Int = 0,
    val speedPreset: Int = 0,
    val micMuted: Int = 0,
    val saveOriginal: Int = 0,
    val stabilization: Int = 0,
)

data class GossCaptureUi(
    val gridMode: Int = 0,
    val levelIndicator: Int = 0,
    val shutterMode: Int = 0,
    val countdownS: Int = 0,
    val nightMode: Int = 0,
    val screenFlashMode: Int = 0,
    val screenFlashIntensity: Float = 1f,
    val screenFlashWarmth: Float = 0.5f,
)

/** One daemon-backed cleaner for the whole SDK. The cleaning action holds
 * only the native handle, never the wrapper, so a dropped engine or session
 * still frees its native side. java.lang.ref.Cleaner lands at API 33; below
 * that the explicit close() path is the only release, so every call site
 * guards on the level before ever touching this object. */
internal object NativeCleaner {
    private val cleaner: Cleaner = Cleaner.create()

    fun register(owner: Any, action: Runnable): Any = cleaner.register(owner, action)

    fun disarm(registration: Any) = (registration as Cleaner.Cleanable).clean()
}

/** Create/destroy/init/resize/render. Confined to the thread that creates
 * it. Destroy sessions before the engine: nativeEngineDestroy tears down any
 * still-live session, after which that session's own handle is stale. On the
 * garbage-collected path a session holds its engine strongly, so a dropped
 * pair is always cleaned session-first. */
class GossEngine private constructor(internal val handle: Long) : AutoCloseable {
    private var closed = false
    /** Frees the native engine if the wrapper is dropped without close();
     * only registered on API 33+, where Cleaner exists. */
    private val cleanable: Any? =
        if (Build.VERSION.SDK_INT >= 33) NativeCleaner.register(this, EngineDisposer(handle)) else null

    private class EngineDisposer(private val handle: Long) : Runnable {
        override fun run() = Gosslens.nativeEngineDestroy(handle)
    }

    /** The per-frame live-broadcast readback reuses one info and one data
     * direct buffer instead of allocating both each published frame; grown
     * to the largest frame, dropped with the engine. */
    private val liveInfo: ByteBuffer = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
    private var liveScratch: ByteBuffer = ByteBuffer.allocateDirect(0)

    private fun liveStage(bytes: Int): ByteBuffer {
        if (liveScratch.capacity() < bytes) liveScratch = ByteBuffer.allocateDirect(bytes)
        liveScratch.clear()
        liveScratch.limit(bytes)
        return liveScratch
    }

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(config: GossEngineConfig? = null): GossEngine {
            val handle = Gosslens.nativeEngineCreate(
                config?.texturePoolCapacity ?: -1,
                config?.stagingPoolCapacity ?: -1,
            )
            check(handle != 0L) { "engine create failed" }
            return GossEngine(handle)
        }
    }

    fun initRenderer(surface: Surface, width: Int, height: Int) {
        check(Gosslens.nativeInitRenderer(handle, surface, width, height) == 0) { "renderer init failed" }
    }

    fun resize(width: Int, height: Int) = Gosslens.nativeResize(handle, width, height)

    /** Requests a screenshot of the next presented frame, written as
     * [path] plus a ".tga" suffix the renderer's own callback appends -
     * debug/test tooling (the conformance run this exists for), never a
     * user-facing control. */
    fun requestScreenshot(path: String): Boolean {
        val bytes = path.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeRequestScreenshot(handle, buffer, bytes.size) == 0
    }

    fun renderFrame(session: GossSession?): Boolean =
        Gosslens.nativeRenderFrame(handle, session?.handle ?: 0L) == 0

    /** Compiles a text prompt into a GLF lens manifest on device. The result
     * is ordinary GLF the caller can inspect or pass to activateLens, and needs
     * no assets. A length probe sizes the buffer, then a fill call writes it. */
    fun compilePrompt(prompt: String): String {
        val bytes = prompt.toByteArray(Charsets.UTF_8)
        val promptBuffer = ByteBuffer.allocateDirect(maxOf(bytes.size, 1))
        promptBuffer.put(bytes)
        promptBuffer.rewind()
        val len = ByteBuffer.allocateDirect(8).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        Gosslens.nativeCompilePrompt(handle, promptBuffer, bytes.size, probe, 0L, len)
        val needed = len.getLong(0).toInt()
        val out = ByteBuffer.allocateDirect(maxOf(needed, 1))
        Gosslens.nativeCompilePrompt(handle, promptBuffer, bytes.size, out, needed.toLong(), len)
        val written = len.getLong(0).toInt()
        val result = ByteArray(written)
        out.get(result)
        return String(result, Charsets.UTF_8)
    }

    /** Starts recording the session's rendered frames, effects baked
     * in, into an MP4 at [path]. One recording per engine; every
     * rendered frame appends until [stopRecording]. */
    fun startRecording(session: GossSession, path: String, width: Int = 0, height: Int = 0, bitrate: Int = 0, hevc: Boolean = false): Boolean {
        val bytes = path.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeRecordingStart(handle, session.handle, buffer, bytes.size, width, height, bitrate, if (hevc) 1 else 0) == 0
    }

    /** Stops the recording, flushing in-flight frames and finalizing
     * the file. */
    fun stopRecording(): Boolean = Gosslens.nativeRecordingStop(handle) == 0

    /** Feeds interleaved f32 PCM into the session: the engine's level
     * and beat analysis drives audio triggers, and an active recording
     * muxes it where the backend supports audio. [samples] is a direct
     * float buffer. */
    fun submitAudio(session: GossSession, samples: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int, timestampUs: Long): Boolean =
        Gosslens.nativeSubmitAudio(session.handle, samples, frameCount, sampleRate, channels, timestampUs) == 0

    /** Renders like renderFrame and returns the composited output
     * encoded as PNG bytes, sized by a probe call first. Deterministic:
     * the same composited pixels, the same bytes. Null when the
     * renderer is unavailable. */
    fun capturePhoto(session: GossSession?): ByteArray? {
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        val probeStatus = Gosslens.nativeCapturePhoto(handle, session?.handle ?: 0L, probe, 0L, info)
        val needed = info.getLong(0)
        if (probeStatus == 0 && needed == 0L) return ByteArray(0)
        if (needed <= 0L) return null
        val data = ByteBuffer.allocateDirect(needed.toInt())
        if (Gosslens.nativeCapturePhoto(handle, session?.handle ?: 0L, data, needed, info) != 0) return null
        val encoded = ByteArray(info.getLong(0).toInt())
        data.get(encoded)
        return encoded
    }

    /** The composited frame in a WebRTC format (BGRA8 = 3 by default, NV12 = 0
     * for a hardware encoder), the supported per-frame output for a live
     * broadcast source. width and height are the render size; returns the
     * packed frame bytes, or null when the renderer is away. */
    fun captureLiveFrame(session: GossSession?, width: Int, height: Int, format: Int = 3): ByteArray? {
        if (width <= 0 || height <= 0) return null
        val pixels = width.toLong() * height
        val capacity = if (format == 0) pixels + pixels / 2 else pixels * 4
        val data = liveStage(capacity.toInt())
        if (Gosslens.nativeCaptureLiveFrame(handle, session?.handle ?: 0L, format, data, capacity, liveInfo) != 0) return null
        val frame = ByteArray(capacity.toInt())
        data.rewind()
        data.get(frame)
        return frame
    }

    /** A high-resolution still: the composited frame at its own or a
     * requested resolution, encoded as PNG (0), JPEG (1) or HEIC (2).
     * colorSpace tags the gamut (0 sRGB, 1 P3, 2 Rec2020); bitDepth 16 is
     * the PNG high-bit-depth path. Null when the renderer/backend is away. */
    fun captureStill(session: GossSession?, width: Int = 0, height: Int = 0, supersample: Int = 0, format: Int = 0, quality: Int = 0, colorSpace: Int = 0, bitDepth: Int = 8): ByteArray? {
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        val probeStatus = Gosslens.nativeCaptureStill(handle, session?.handle ?: 0L, width, height, supersample, format, quality, colorSpace, bitDepth, probe, 0L, info)
        val needed = info.getLong(0)
        if (probeStatus == 0 && needed == 0L) return ByteArray(0)
        if (needed <= 0L) return null
        val data = ByteBuffer.allocateDirect(needed.toInt())
        if (Gosslens.nativeCaptureStill(handle, session?.handle ?: 0L, width, height, supersample, format, quality, colorSpace, bitDepth, data, needed, info) != 0) return null
        val encoded = ByteArray(info.getLong(0).toInt())
        data.get(encoded)
        return encoded
    }

    /** Captures the composited frame as a platform photo (1 JPEG, 2 HEIC)
     * at [quality] percent, sized by a probe call first. Lossy and not
     * bit-stable across runs - the PNG [capturePhoto] stays the
     * deterministic surface. Null when the photo backend is away. */
    fun capturePhotoAs(session: GossSession?, format: Int, quality: Int = 0): ByteArray? {
        val info = ByteBuffer.allocateDirect(16).order(ByteOrder.nativeOrder())
        val probe = ByteBuffer.allocateDirect(1)
        val probeStatus = Gosslens.nativeCapturePhotoAs(handle, session?.handle ?: 0L, format, quality, probe, 0L, info)
        val needed = info.getLong(0)
        if (probeStatus == 0 && needed == 0L) return ByteArray(0)
        if (needed <= 0L) return null
        val data = ByteBuffer.allocateDirect(needed.toInt())
        if (Gosslens.nativeCapturePhotoAs(handle, session?.handle ?: 0L, format, quality, data, needed, info) != 0) return null
        val encoded = ByteArray(info.getLong(0).toInt())
        data.get(encoded)
        return encoded
    }

    /** Debug/test tooling only. Renders like renderFrame and reads the
     * composited output back as RGBA8, row 0 first, at the render size;
     * [width] and [height] must be at least the render surface. Null when
     * the renderer is unavailable. */
    fun captureFrame(session: GossSession?, width: Int, height: Int): ByteArray? {
        if (width <= 0 || height <= 0) return null
        val info = ByteBuffer.allocateDirect(8).order(ByteOrder.nativeOrder())
        val capacity = width * height * 4
        val data = ByteBuffer.allocateDirect(capacity)
        if (Gosslens.nativeCaptureFrame(handle, session?.handle ?: 0L, data, capacity.toLong(), info) != 0) return null
        val frame = ByteArray(capacity)
        data.get(frame)
        return frame
    }

    /** Renders the composited frame straight into a caller-supplied external
     * texture ([nativeHandle], a platform texture object) instead of reading
     * it back, zero-copy. False means the override is warming up (skip this
     * frame and retry) or the path is unavailable on this backend. */
    fun renderToLiveTexture(session: GossSession, nativeHandle: Long, width: Int, height: Int): Boolean =
        Gosslens.nativeRenderToLiveTexture(handle, session.handle, nativeHandle, width, height) == 0

    /** Releases the persistent wrap renderToLiveTexture keeps for one
     * external texture, when a publish surface retires before the engine
     * does. False for a handle with no live wrap. */
    fun releaseLiveTexture(nativeHandle: Long): Boolean =
        Gosslens.nativeReleaseLiveTexture(handle, nativeHandle) == 0

    // Idempotent like destroy() everywhere else - a second close() must
    // not hand the native side an already-freed handle. Disarming the
    // Cleaner runs the same disposer once; below API 33 there is no
    // registration, so free the handle directly.
    override fun close() {
        if (closed) return
        closed = true
        if (cleanable != null) NativeCleaner.disarm(cleanable) else Gosslens.nativeEngineDestroy(handle)
    }
}

/** One tracking result read back from the core. The buffer mirrors the
 * frozen C layout; parse() lifts the fields into Kotlin values without
 * allocating per frame. */
class GossFaceResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.FACE_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var presence: Float = 0f; private set
    var landmarkCount: Int = 0; private set

    /** x, y frame pixels and z, three floats per landmark. */
    val landmarks = FloatArray(Gosslens.FACE_LANDMARK_COUNT * 3)
    val blendshapes = FloatArray(Gosslens.FACE_BLENDSHAPE_COUNT)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        presence = buffer.float
        landmarkCount = buffer.int
        buffer.asFloatBuffer().let { floats ->
            floats.get(landmarks)
            floats.get(blendshapes)
        }
    }
}

/** The live signals one tick evaluates a lens's compiled triggers
 * against. The buffer mirrors the frozen goss_lens_signals layout
 * (booleans and a reserved byte, then the padding to the first double
 * at offset 8, then blendshapes at offset 24) - absolute puts, not
 * relative, so this doesn't depend on writing the padding by hand. */
class GossLensSignals {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.LENS_SIGNALS_BYTES).order(java.nio.ByteOrder.nativeOrder())

    /** blendshapes may be shorter than FACE_BLENDSHAPE_COUNT; the rest
     * reads as zero. Pass hasFace = false when no face is tracked -
     * every face-driven signal then reads false regardless of what
     * blendshapes holds. */
    fun set(hasFace: Boolean, handsPresent: Boolean, tap: Boolean, worldTrackingState: Double, audioLevel: Double, blendshapes: FloatArray) {
        buffer.put(0, if (hasFace) 1 else 0)
        buffer.put(1, if (handsPresent) 1 else 0)
        buffer.put(2, if (tap) 1 else 0)
        buffer.put(3, 0)
        buffer.putDouble(8, worldTrackingState)
        buffer.putDouble(16, audioLevel)
        val floats = buffer.duplicate().order(buffer.order()).asFloatBuffer()
        for (i in 0 until Gosslens.FACE_BLENDSHAPE_COUNT) {
            floats.put(6 + i, if (i < blendshapes.size) blendshapes[i] else 0f)
        }
    }
}

/** One reusable hand tracking readout. The buffer mirrors the frozen C
 * layout; parse() lifts the fields into flat per-hand arrays without
 * allocating per frame. handedness is the model's score that the hand
 * is a right hand; gestures hold GESTURE_* classes, NONE when the
 * enabled bundle carries no gesture models. */
class GossHandResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.HAND_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var handCount: Int = 0; private set

    val presences = FloatArray(Gosslens.HAND_MAX)
    val handednesses = FloatArray(Gosslens.HAND_MAX)
    val gestures = IntArray(Gosslens.HAND_MAX)
    val gestureScores = FloatArray(Gosslens.HAND_MAX)

    /** Hand h's point p sits at (h * HAND_LANDMARK_COUNT + p) * 3. */
    val landmarks = FloatArray(Gosslens.HAND_MAX * Gosslens.HAND_LANDMARK_COUNT * 3)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        handCount = buffer.int
        buffer.int
        for (handAt in 0 until Gosslens.HAND_MAX) {
            presences[handAt] = buffer.float
            handednesses[handAt] = buffer.float
            gestures[handAt] = buffer.int
            gestureScores[handAt] = buffer.float
            val floats = buffer.asFloatBuffer()
            floats.get(landmarks, handAt * Gosslens.HAND_LANDMARK_COUNT * 3, Gosslens.HAND_LANDMARK_COUNT * 3)
            buffer.position(buffer.position() + Gosslens.HAND_LANDMARK_COUNT * 3 * 4)
        }
    }
}

/** One reusable pose tracking readout. The buffer mirrors the frozen C
 * layout; parse() lifts the fields into flat arrays without allocating
 * per frame. */
class GossPoseResult {
    internal val buffer: ByteBuffer =
        ByteBuffer.allocateDirect(Gosslens.POSE_RESULT_BYTES).order(java.nio.ByteOrder.nativeOrder())

    var frameSerial: Long = 0; private set
    var timestampUs: Long = 0; private set
    var presence: Float = 0f; private set
    var landmarkCount: Int = 0; private set

    /** x, y frame pixels and z, three floats per landmark. */
    val landmarks = FloatArray(Gosslens.POSE_LANDMARK_COUNT * 3)
    val visibilities = FloatArray(Gosslens.POSE_LANDMARK_COUNT)
    val presences = FloatArray(Gosslens.POSE_LANDMARK_COUNT)

    internal fun parse() {
        buffer.rewind()
        frameSerial = buffer.long
        timestampUs = buffer.long
        presence = buffer.float
        landmarkCount = buffer.int
        buffer.asFloatBuffer().let { floats ->
            floats.get(landmarks)
            floats.get(visibilities)
            floats.get(presences)
        }
    }
}

/** Per-preview runtime. Every call and the teardown dereference engine
 * state, so the session holds its engine strongly: the engine cannot be
 * collected while a session is live, which keeps nativeSessionDestroy
 * ordered before nativeEngineDestroy on the garbage-collected path. */
class GossSession private constructor(
    private val engine: GossEngine,
    internal val handle: Long,
) : AutoCloseable {
    private var closed = false
    /** Frees the native session if the wrapper is dropped without close();
     * only registered on API 33+, where Cleaner exists. */
    private val cleanable: Any? =
        if (Build.VERSION.SDK_INT >= 33) NativeCleaner.register(this, SessionDisposer(handle)) else null

    private class SessionDisposer(private val handle: Long) : Runnable {
        override fun run() = Gosslens.nativeSessionDestroy(handle)
    }

    /** A per-session direct staging buffer the per-frame submit and readback
     * paths reuse instead of allocating a fresh direct buffer each call -
     * direct buffers are finalizer-reclaimed, the worst churn class on
     * Android. Grown to the largest frame, dropped with the session. */
    private var scratch: ByteBuffer = ByteBuffer.allocateDirect(0).order(ByteOrder.nativeOrder())

    private fun stage(bytes: Int): ByteBuffer {
        if (scratch.capacity() < bytes) {
            scratch = ByteBuffer.allocateDirect(bytes).order(ByteOrder.nativeOrder())
        }
        scratch.clear()
        scratch.limit(bytes)
        return scratch
    }

    companion object {
        /** Null config means the core's own defaults, same as C's null. */
        fun create(engine: GossEngine, config: GossSessionConfig? = null): GossSession {
            val handle = Gosslens.nativeSessionCreate(engine.handle, config?.frameBudgetUs ?: -1)
            check(handle != 0L) { "session create failed" }
            return GossSession(engine, handle)
        }
    }

    fun submitFrameCopy(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitFrameCopy(
        handle, y, yStride, uv, uvStride, width, height,
        Gosslens.flagsFor(rotationDegrees, mirrored),
        colorStandard, colorRange, timestampUs,
    ) == 0

    /** Zero-copy submission: up to three platform texture handles (an
     * AHardwareBuffer-backed image or a GL texture) as opaque pointer-sized
     * values in [planes]. The platform objects must outlive the next rendered
     * frame; [pixelFormat] is a PIXEL_* value. Prefer this over the copy paths. */
    fun submitFrame(
        planes: LongArray,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        pixelFormat: Int = Gosslens.PIXEL_NV12,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitFrame(
        handle,
        if (planes.isNotEmpty()) planes[0] else 0L,
        if (planes.size > 1) planes[1] else 0L,
        if (planes.size > 2) planes[2] else 0L,
        planes.size, width, height, pixelFormat,
        Gosslens.flagsFor(rotationDegrees, mirrored),
        colorStandard, colorRange, timestampUs,
    ) == 0

    /** The CPU-copy path for a single interleaved BGRA8/RGBA8 plane - a
     * Bitmap or decoded video frame's own byte buffer, with no native GPU
     * handle behind it. [pixelFormat] is PIXEL_BGRA8 or PIXEL_RGBA8. */
    fun submitFrameRgbaCopy(
        rgba: ByteBuffer,
        stride: Int,
        width: Int,
        height: Int,
        pixelFormat: Int = Gosslens.PIXEL_RGBA8,
        rotationDegrees: Int = 0,
        mirrored: Boolean = false,
        timestampUs: Long = 0,
    ): Boolean = Gosslens.nativeSubmitFrameRgbaCopy(
        handle, rgba, stride, width, height, pixelFormat,
        Gosslens.flagsFor(rotationDegrees, mirrored), timestampUs,
    ) == 0

    fun reportFrame(frameTimeUs: Int, thermal: Int): Int =
        Gosslens.nativeReportFrame(handle, frameTimeUs, thermal)

    fun degradeLevel(): Int = Gosslens.nativeDegradeLevel(handle)

    fun enableFaceTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnableFaceTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disableFaceTracking() = Gosslens.nativeDisableFaceTracking(handle)

    /** Stands the hand tracking worker up from a hand landmarker or
     * gesture recognizer task bundle; up to two hands publish per frame,
     * with canned gestures scored when the bundle carries the models. */
    fun enableHandTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnableHandTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disableHandTracking() = Gosslens.nativeDisableHandTracking(handle)

    /** Stands the pose tracking worker up from a pose landmarker task
     * bundle; one 33-point body publishes per frame. */
    fun enablePoseTracking(taskBundle: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnablePoseTracking(handle, taskBundle, taskBundle.remaining(), threads) == 0

    fun disablePoseTracking() = Gosslens.nativeDisablePoseTracking(handle)

    /** Upper-body pose mode: while enabled the tracked pose reports only the
     * upper body; the lower-body joints (knees down) read absent. */
    fun setPoseUpperBody(enabled: Boolean): Boolean = Gosslens.nativeSetPoseUpperBody(handle, if (enabled) 1 else 0) == 0

    /** Fills [result] with the newest pose tracking output; false until
     * the worker publishes its first result. */
    fun poseResult(result: GossPoseResult): Boolean {
        val status = Gosslens.nativePoseResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    private val facePoseBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(16 * 4).order(java.nio.ByteOrder.nativeOrder())

    private val faceRegionBuffer: ByteBuffer =
        ByteBuffer.allocateDirect(3 * 4).order(java.nio.ByteOrder.nativeOrder())

    /** Fills [matrix] with the column-major head transform - canonical
     * metric space into frame pixels; false until a face is tracked. */
    fun facePose(matrix: FloatArray): Boolean {
        require(matrix.size >= 16)
        if (Gosslens.nativeFacePose(handle, facePoseBuffer) != 0) return false
        facePoseBuffer.rewind()
        facePoseBuffer.asFloatBuffer().get(matrix, 0, 16)
        return true
    }

    /** The tracked point (x, y in frame pixels, z in the same scale) of a
     * named FACE_REGION_*, or null until a face is tracked. */
    fun faceRegion(region: Int): FloatArray? {
        if (Gosslens.nativeFaceRegion(handle, region, faceRegionBuffer) != 0) return null
        faceRegionBuffer.rewind()
        val out = FloatArray(3)
        faceRegionBuffer.asFloatBuffer().get(out, 0, 3)
        return out
    }

    /** The tracked point (x, y in frame pixels, z in the same scale) of a
     * named BODY_JOINT_*, or null until a body is tracked. */
    fun bodyJoint(joint: Int): FloatArray? {
        if (Gosslens.nativeBodyJoint(handle, joint, faceRegionBuffer) != 0) return null
        faceRegionBuffer.rewind()
        val out = FloatArray(3)
        faceRegionBuffer.asFloatBuffer().get(out, 0, 3)
        return out
    }

    /** The tracked point (x, y in frame pixels, z in the same scale) of a
     * named HAND_JOINT_* on the [handIndex]-th hand, or null until that hand
     * is tracked. */
    fun handJoint(joint: Int, handIndex: Int = 0): FloatArray? {
        if (Gosslens.nativeHandJoint(handle, handIndex, joint, faceRegionBuffer) != 0) return null
        faceRegionBuffer.rewind()
        val out = FloatArray(3)
        faceRegionBuffer.asFloatBuffer().get(out, 0, 3)
        return out
    }

    /** Fills [result] with the newest hand tracking output; false until
     * the worker publishes its first result. */
    fun handResult(result: GossHandResult): Boolean {
        val status = Gosslens.nativeHandResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    fun trackFrame(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeTrackFrame(
        handle, y, yStride, uv, uvStride, width, height, colorStandard, colorRange, timestampUs,
    ) == 0

    /** Runs each selfie-source splat.cloud once over one NV12 still, so a
     * photoreal avatar is generated from a photo and then held off the camera. */
    fun submitAvatarSource(
        y: ByteBuffer,
        yStride: Int,
        uv: ByteBuffer,
        uvStride: Int,
        width: Int,
        height: Int,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitAvatarSource(
        handle, y, yStride, uv, uvStride, width, height, colorStandard, colorRange, timestampUs,
    ) == 0

    /** Stands the segmentation worker up from a raw model - a selfie or hair
     * segmenter .tflite; [model] is a direct buffer of the model bytes. Once
     * enabled, trackFrame feeds it the same frame it feeds the trackers. */
    fun enableSegmentation(model: ByteBuffer, threads: Int): Boolean =
        Gosslens.nativeEnableSegmentation(handle, model, model.remaining(), threads) == 0

    fun disableSegmentation() = Gosslens.nativeDisableSegmentation(handle)

    /** Feeds one frame's tracked face landmarks in directly (x, y in frame
     * pixels, z in the same scale, three floats per point); an empty array
     * clears them. The web-only path for the landmark-driven beauty effects;
     * UNSUPPORTED off web, where trackFrame feeds the same effects instead. */
    fun setFaceLandmarks(points: FloatArray): Boolean {
        if (points.isEmpty()) return Gosslens.nativeSetFaceLandmarks(handle, stage(4), 0) == 0
        val buf = stage(points.size * 4)
        buf.asFloatBuffer().put(points)
        buf.rewind()
        return Gosslens.nativeSetFaceLandmarks(handle, buf, points.size / 3) == 0
    }

    /** Stands the beauty chain up; [resourceDir] holds the effect engine's
     * shader and image assets on disk. */
    fun enableBeauty(resourceDir: String): Boolean {
        val bytes = resourceDir.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size + 1)
        buffer.put(bytes)
        buffer.put(0)
        buffer.rewind()
        return Gosslens.nativeEnableBeauty(handle, buffer, bytes.size) == 0
    }

    fun disableBeauty() = Gosslens.nativeDisableBeauty(handle)

    /** Effects in order: smooth 0, whiten 1, thin face 2, big eye 3,
     * lipstick 4, blush 5; values clamp to zero and one. */
    fun setBeauty(effect: Int, amount: Float): Boolean =
        Gosslens.nativeSetBeauty(handle, effect, amount) == 0

    fun setSmooth(amount: Float) = setBeauty(0, amount)
    fun setWhiten(amount: Float) = setBeauty(1, amount)
    fun setThinFace(amount: Float) = setBeauty(2, amount)
    fun setBigEye(amount: Float) = setBeauty(3, amount)
    fun setLipstick(amount: Float) = setBeauty(4, amount)
    fun setBlush(amount: Float) = setBeauty(5, amount)

    /** Web only; UNSUPPORTED on every other target, where whiten runs through
     * the native beauty engine. Uploads one of whiten's four lookup textures
     * (slot 0 gray, 1 origin, 2 skin, 3 custom); [rgba] is width by height
     * RGBA8. Whiten stays inert until all four slots are loaded. */
    fun setBeautyLut(slot: Int, rgba: ByteArray, width: Int, height: Int): Boolean {
        val buf = ByteBuffer.allocateDirect(rgba.size).order(ByteOrder.nativeOrder())
        buf.put(rgba)
        buf.rewind()
        return Gosslens.nativeSetBeautyLut(handle, slot, buf, width, height) == 0
    }

    /** Web only; UNSUPPORTED on every other target. Uploads lipstick's (4) or
     * blush's (5) own source image; [rgba] is width by height RGBA8. */
    fun setBeautyMakeupTexture(effect: Int, rgba: ByteArray, width: Int, height: Int): Boolean {
        val buf = ByteBuffer.allocateDirect(rgba.size).order(ByteOrder.nativeOrder())
        buf.put(rgba)
        buf.rewind()
        return Gosslens.nativeSetBeautyMakeupTexture(handle, effect, buf, width, height) == 0
    }

    fun beautifyFrame(rgbaIn: ByteBuffer, rgbaOut: ByteBuffer, width: Int, height: Int): Boolean =
        Gosslens.nativeBeautifyFrame(handle, rgbaIn, rgbaOut, width, height) == 0

    /** Fills [result] with the newest tracking output; false until the
     * worker publishes its first result. */
    fun faceResult(result: GossFaceResult): Boolean {
        val status = Gosslens.nativeFaceResult(handle, result.buffer)
        if (status != 0) return false
        result.parse()
        return true
    }

    /** Submits the faces tracked this frame for the multi-face path, so a
     * lens can instance effects across every face and the face-anchor render
     * fans out. An empty list clears the path back to the single internal
     * tracker; faces past FACE_MAX are ignored. */
    fun submitFaces(faces: List<GossFaceResult>): Boolean {
        if (faces.isEmpty()) return Gosslens.nativeSubmitFaces(handle, stage(1), 0) == 0
        val packed = stage(faces.size * Gosslens.FACE_RESULT_BYTES)
        for (f in faces) {
            f.buffer.rewind()
            packed.put(f.buffer)
        }
        packed.rewind()
        return Gosslens.nativeSubmitFaces(handle, packed, faces.size) == 0
    }

    /** The number of faces the last submitFaces kept, zero to FACE_MAX. */
    fun faceCount(): Int = Gosslens.nativeFaceCount(handle).coerceAtLeast(0)

    /** Fills [result] with the index-th submitted face; false once index
     * reaches faceCount, so a caller loops zero to faceCount. */
    fun faceResultAt(index: Int, result: GossFaceResult): Boolean {
        if (Gosslens.nativeFaceResultAt(handle, index, result.buffer) != 0) return false
        result.parse()
        return true
    }

    /** Submits the bodies tracked this frame for the multi-person path, so a
     * lens can instance effects across every body. An empty list clears the
     * path; bodies past BODY_MAX are ignored. */
    fun submitBodies(bodies: List<GossPoseResult>): Boolean {
        if (bodies.isEmpty()) return Gosslens.nativeSubmitBodies(handle, stage(1), 0) == 0
        val packed = stage(bodies.size * Gosslens.POSE_RESULT_BYTES)
        for (b in bodies) {
            b.buffer.rewind()
            packed.put(b.buffer)
        }
        packed.rewind()
        return Gosslens.nativeSubmitBodies(handle, packed, bodies.size) == 0
    }

    /** Submits one frame's depth map from the host AR backend (ARCore Depth
     * API): width by height metres per pixel, row major, with the near and
     * far metres that bound it. An empty array clears it. Kept for depth
     * occlusion against the rendered content. */
    fun submitDepth(depth: FloatArray, width: Int, height: Int, near: Float, far: Float): Boolean {
        if (depth.isEmpty()) return Gosslens.nativeSubmitDepth(handle, stage(4), 0, 0, 0f, 0f) == 0
        val buf = stage(depth.size * 4)
        buf.asFloatBuffer().put(depth)
        buf.rewind()
        return Gosslens.nativeSubmitDepth(handle, buf, width, height, near, far) == 0
    }

    /** Segments a host-provided still image through the running segmenter:
     * rgba is width by height RGBA8 pixels, row major. The mask reaches the
     * active lens the way a camera frame's would. */
    fun submitSegmentationImage(rgba: ByteArray, width: Int, height: Int): Boolean {
        val buf = stage(rgba.size)
        buf.put(rgba)
        buf.rewind()
        return Gosslens.nativeSubmitSegmentationImage(handle, buf, width, height) == 0
    }

    /** Samples a reference photo's makeup color per face part, so a tint.pass
     * with a reference source paints the live face in that color. rgba is
     * width by height RGBA8; landmarks is the reference face's 478 x, y, z
     * points. An empty landmarks array clears the reference. */
    fun setMakeupReference(rgba: ByteArray, width: Int, height: Int, landmarks: FloatArray): Boolean {
        if (landmarks.isEmpty()) return Gosslens.nativeSetMakeupReference(handle, ByteBuffer.allocateDirect(4), 0, 0, ByteBuffer.allocateDirect(4), 0) == 0
        val rbuf = ByteBuffer.allocateDirect(rgba.size).order(ByteOrder.nativeOrder())
        rbuf.put(rgba)
        rbuf.rewind()
        val lbuf = ByteBuffer.allocateDirect(landmarks.size * 4).order(ByteOrder.nativeOrder())
        lbuf.asFloatBuffer().put(landmarks)
        lbuf.rewind()
        return Gosslens.nativeSetMakeupReference(handle, rbuf, width, height, lbuf, landmarks.size / 3) == 0
    }

    /** The number of bodies the last submitBodies kept, zero to BODY_MAX. */
    fun bodyCount(): Int = Gosslens.nativeBodyCount(handle).coerceAtLeast(0)

    /** Fills [result] with the index-th submitted body; false once index
     * reaches bodyCount, so a caller loops zero to bodyCount. */
    fun bodyResultAt(index: Int, result: GossPoseResult): Boolean {
        if (Gosslens.nativeBodyResultAt(handle, index, result.buffer) != 0) return false
        result.parse()
        return true
    }

    /** Replaces any currently active lens with the one manifestJson
     * describes, splicing its nodes into the session graph. */
    fun activateLens(manifestJson: ByteArray): Boolean {
        val buffer = ByteBuffer.allocateDirect(manifestJson.size)
        buffer.put(manifestJson)
        buffer.rewind()
        return Gosslens.nativeActivateLens(handle, buffer, manifestJson.size) == 0
    }

    /** Activates a lens from an on-disk .glens bundle directory. */
    fun activateLensFromDirectory(bundlePath: String): Boolean {
        val bytes = bundlePath.toByteArray(Charsets.UTF_8)
        val buffer = ByteBuffer.allocateDirect(bytes.size)
        buffer.put(bytes)
        buffer.rewind()
        return Gosslens.nativeActivateLensFromDirectory(handle, buffer, bytes.size) == 0
    }

    fun deactivateLens() = Gosslens.nativeDeactivateLens(handle)

    /** Advances the active lens by [dtUs] of real time and applies
     * whatever effect values its triggers/ramps changed to the beauty
     * chain, if one is enabled. False with no active lens. */
    fun tickLens(dtUs: Int, signals: GossLensSignals): Boolean =
        Gosslens.nativeTickLens(handle, dtUs, signals.buffer) == 0

    /** Reads a live parameter of the active lens by name, including whatever
     * a script node last wrote. Null with no active lens or no such name. */
    fun parameterValue(name: String): Float? {
        val nameBytes = name.toByteArray(Charsets.UTF_8)
        val nameBuf = ByteBuffer.allocateDirect(nameBytes.size).apply { put(nameBytes); rewind() }
        val outBuf = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        return if (Gosslens.nativeParameterValue(handle, nameBuf, nameBytes.size, outBuf) == 0) outBuf.getFloat(0) else null
    }

    /** Pulls the next block of mixed lens audio into a direct [out] buffer
     * (frames interleaved s16) that play_sound triggers produced, for the app
     * to route to platform audio out. */
    fun pullAudio(out: ByteBuffer, frames: Int): Boolean =
        Gosslens.nativePullAudio(handle, out, frames) == 0

    /** Folds the active lens sound into the caller's outgoing call/live track:
     * [mic] (interleaved f32 at [sampleRate]/[channels], or null for silence)
     * summed with the 48 kHz mono lens mixer resampled to that rate, into [out]
     * (frameCount*channels s16). Advances the mixer once, replacing [pullAudio]. */
    fun mixOutputAudio(mic: ByteBuffer?, out: ByteBuffer, frameCount: Int, sampleRate: Int, channels: Int): Boolean =
        Gosslens.nativeMixOutputAudio(handle, mic, out, frameCount, sampleRate, channels) == 0

    /** Stores validated camera-hardware intent; the engine normalizes it. Read
     * it back with [cameraControls] and drive CameraX with the result. */
    fun setCameraControls(c: GossCameraControls): Boolean {
        val buf = ByteBuffer.allocateDirect(56).order(ByteOrder.nativeOrder())
        buf.putInt(c.flashMode); buf.putInt(c.torch); buf.putInt(c.focusMode); buf.putInt(c.exposureMode)
        buf.putFloat(c.focusPointX); buf.putFloat(c.focusPointY); buf.putInt(c.exposureLinked)
        buf.putFloat(c.exposurePointX); buf.putFloat(c.exposurePointY); buf.putFloat(c.exposureBiasEv)
        buf.putFloat(c.zoomFactor); buf.putFloat(c.maxZoomFactor); buf.putInt(c.mirrorSavePolicy); buf.putInt(0)
        buf.rewind()
        return Gosslens.nativeSetCameraControls(handle, buf) == 0
    }

    /** The normalized camera controls the app applies to the platform camera. */
    fun cameraControls(): GossCameraControls? {
        val buf = ByteBuffer.allocateDirect(56).order(ByteOrder.nativeOrder())
        if (Gosslens.nativeCameraControls(handle, buf) != 0) return null
        return GossCameraControls(
            buf.getInt(0), buf.getInt(4), buf.getInt(8), buf.getInt(12),
            buf.getFloat(16), buf.getFloat(20), buf.getInt(24),
            buf.getFloat(28), buf.getFloat(32), buf.getFloat(36),
            buf.getFloat(40), buf.getFloat(44), buf.getInt(48),
        )
    }

    /** Stores the recording policy the SDK applies to the platform recorder. */
    fun setRecordingPolicy(p: GossRecordingPolicy): Boolean {
        val buf = ByteBuffer.allocateDirect(40).order(ByteOrder.nativeOrder())
        buf.putInt(p.maxDurationMs); buf.putInt(p.minClipMs); buf.putInt(p.segmentMode); buf.putInt(p.loopPlayback)
        buf.putInt(p.speedPreset); buf.putInt(p.micMuted); buf.putInt(p.saveOriginal); buf.putInt(p.stabilization)
        buf.putInt(0); buf.putInt(0)
        buf.rewind()
        return Gosslens.nativeSetRecordingPolicy(handle, buf) == 0
    }

    fun recordingPolicy(): GossRecordingPolicy? {
        val buf = ByteBuffer.allocateDirect(40).order(ByteOrder.nativeOrder())
        if (Gosslens.nativeRecordingPolicy(handle, buf) != 0) return null
        return GossRecordingPolicy(
            buf.getInt(0), buf.getInt(4), buf.getInt(8), buf.getInt(12),
            buf.getInt(16), buf.getInt(20), buf.getInt(24), buf.getInt(28),
        )
    }

    /** Stores the capture-UI intent the app renders (grid, timer, night mode, flash). */
    fun setCaptureUi(u: GossCaptureUi): Boolean {
        val buf = ByteBuffer.allocateDirect(40).order(ByteOrder.nativeOrder())
        buf.putInt(u.gridMode); buf.putInt(u.levelIndicator); buf.putInt(u.shutterMode); buf.putInt(u.countdownS)
        buf.putInt(u.nightMode); buf.putInt(u.screenFlashMode); buf.putFloat(u.screenFlashIntensity); buf.putFloat(u.screenFlashWarmth)
        buf.putInt(0); buf.putInt(0)
        buf.rewind()
        return Gosslens.nativeSetCaptureUi(handle, buf) == 0
    }

    fun captureUi(): GossCaptureUi? {
        val buf = ByteBuffer.allocateDirect(40).order(ByteOrder.nativeOrder())
        if (Gosslens.nativeCaptureUi(handle, buf) != 0) return null
        return GossCaptureUi(
            buf.getInt(0), buf.getInt(4), buf.getInt(8), buf.getInt(12),
            buf.getInt(16), buf.getInt(20), buf.getFloat(24), buf.getFloat(28),
        )
    }

    /** Fires a named event the next [tickLens] delivers to the lens's
     * event('name') triggers for one tick. */
    fun fireEvent(name: String): Boolean {
        val bytes = name.toByteArray(Charsets.UTF_8)
        val buf = ByteBuffer.allocateDirect(bytes.size).apply { put(bytes); rewind() }
        return Gosslens.nativeFireEvent(handle, buf, bytes.size) == 0
    }

    private fun nameBuf(name: String): Pair<ByteBuffer, Int> {
        val b = name.toByteArray(Charsets.UTF_8)
        return ByteBuffer.allocateDirect(b.size).apply { put(b); rewind() } to b.size
    }

    /** Registers a named RGBA source for multi-source composition. */
    fun defineSource(name: String): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeDefineSource(handle, buf, n) == 0
    }

    /** Removes a named source. */
    fun removeSource(name: String): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeRemoveSource(handle, buf, n) == 0
    }

    /** Uploads one RGBA/BGRA frame into a named source ([pixelFormat] 3 BGRA, 4 RGBA). */
    fun submitSourceFrameRgba(name: String, rgba: ByteBuffer, width: Int, height: Int, stride: Int, pixelFormat: Int = 4): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeSubmitSourceFrameRgba(handle, buf, n, rgba, width, height, stride, pixelFormat) == 0
    }

    /** Arranges the camera and named sources: 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid. */
    fun setLayout(arrangement: Int): Boolean = Gosslens.nativeSetLayout(handle, arrangement) == 0

    fun clearLayout(): Boolean = Gosslens.nativeClearLayout(handle) == 0

    /** Sets a source's composite blend: opacity, key mode (0 none, 1 matte, 2 chroma), chroma color, similarity. Name "camera" is the base. */
    fun setSourceComposite(name: String, opacity: Float = 1f, keyMode: Int = 0, keyR: Float = 0f, keyG: Float = 0f, keyB: Float = 0f, similarity: Float = 0f): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeSetSourceComposite(handle, buf, n, opacity, keyMode, keyR, keyG, keyB, similarity) == 0
    }

    /** Defines a screen-share source whose frame letterboxes to fit its cell instead of stretching. */
    fun defineScreenShare(name: String): Boolean {
        val (buf, n) = nameBuf(name)
        return Gosslens.nativeDefineScreenShare(handle, buf, n) == 0
    }

    /** Feeds a location fix for on-device geo.in_region membership. */
    fun submitLocation(latitude: Double, longitude: Double, accuracyM: Float, timestampUs: Long): Boolean =
        Gosslens.nativeSubmitLocation(handle, latitude, longitude, accuracyM, timestampUs) == 0

    /** Sets the geofence circle the app derives from a lens's intended place. */
    fun setGeofence(latitude: Double, longitude: Double, radiusM: Double): Boolean =
        Gosslens.nativeSetGeofence(handle, latitude, longitude, radiusM) == 0

    fun clearGeofence(): Boolean = Gosslens.nativeClearGeofence(handle) == 0

    /** Sets the geofence to an axis-aligned lat/lon box. */
    fun setGeofenceBBox(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double): Boolean =
        Gosslens.nativeSetGeofenceBbox(handle, minLat, minLon, maxLat, maxLon) == 0

    /** Sets the geofence to a polygon ring of (lat, lon) pairs, three to 64 vertices. */
    fun setGeofencePolygon(vertices: List<Pair<Double, Double>>): Boolean {
        val buffer = ByteBuffer.allocateDirect(vertices.size * 2 * 8).order(ByteOrder.nativeOrder())
        val doubles = buffer.asDoubleBuffer()
        for (v in vertices) { doubles.put(v.first); doubles.put(v.second) }
        return Gosslens.nativeSetGeofencePolygon(handle, buffer, vertices.size) == 0
    }

    /** Sets the worst fix accuracy (meters) that still counts as inside a region; zero clears the gate. */
    fun setGeoAccuracy(maxAccuracyM: Float): Boolean = Gosslens.nativeSetGeoAccuracy(handle, maxAccuracyM) == 0

    /** Sets the color and half-width (normalized units) the next stroke opens with. */
    fun setBrushStyle(r: Float, g: Float, b: Float, a: Float, width: Float): Boolean =
        Gosslens.nativeBrushSetStyle(handle, r, g, b, a, width) == 0

    /** Opens a stroke in the current style. A fresh stroke drops the redo stack. */
    fun beginStroke(): Boolean = Gosslens.nativeBrushBegin(handle) == 0

    /** Adds a point to the open stroke, in normalized screen space (0..1). */
    fun addStrokePoint(x: Float, y: Float): Boolean = Gosslens.nativeBrushPoint(handle, x, y) == 0

    /** Commits the open stroke. A stroke of fewer than two points is dropped. */
    fun endStroke(): Boolean = Gosslens.nativeBrushEnd(handle) == 0

    fun undoStroke(): Boolean = Gosslens.nativeBrushUndo(handle) == 0
    fun redoStroke(): Boolean = Gosslens.nativeBrushRedo(handle) == 0
    fun clearStrokes(): Boolean = Gosslens.nativeBrushClear(handle) == 0

    /** The brush preset the next stroke opens with. */
    enum class BrushMode(val raw: Int) { PEN(0), HIGHLIGHTER(1), MARKER(2), NEON(3) }

    fun setBrushMode(mode: BrushMode): Boolean = Gosslens.nativeBrushSetMode(handle, mode.raw) == 0

    /** Erases committed strokes within radius (normalized units) of the point; returns how many, or -1 on a bad session. */
    fun eraseStrokes(x: Float, y: Float, radius: Float): Int = Gosslens.nativeBrushEraseAt(handle, x, y, radius)

    /** The world-anchored brush. Points are pushed in the world frame world tracking reports; the engine projects and draws them so a stroke stays fixed in the scene. */
    fun setARBrushStyle(r: Float, g: Float, b: Float, a: Float, width: Float): Boolean =
        Gosslens.nativeArBrushSetStyle(handle, r, g, b, a, width) == 0

    fun setARBrushMode(mode: BrushMode): Boolean = Gosslens.nativeArBrushSetMode(handle, mode.raw) == 0
    fun beginARStroke(): Boolean = Gosslens.nativeArBrushBegin(handle) == 0
    fun addARStrokePoint(x: Float, y: Float, z: Float): Boolean = Gosslens.nativeArBrushPoint(handle, x, y, z) == 0
    fun endARStroke(): Boolean = Gosslens.nativeArBrushEnd(handle) == 0
    fun undoARStroke(): Boolean = Gosslens.nativeArBrushUndo(handle) == 0
    fun clearARStrokes(): Boolean = Gosslens.nativeArBrushClear(handle) == 0
    /// Feeds one screen touch event so the engine recognizes the gestures a
    /// lens reacts to. phase is 0 began, 1 moved, 2 ended, 3 cancelled;
    /// pointerId names the finger; x and y are normalized 0..1 over the frame.
    fun touch(phase: Int, pointerId: Int = 0, x: Float, y: Float): Boolean =
        Gosslens.nativeTouch(handle, phase, pointerId, x, y) == 0

    /// A device haptic a haptic trigger asked for: the style index (0 light..7
    /// failure) and a 0..1 intensity hint.
    data class Haptic(val style: Int, val intensity: Float)

    private val hapticBuffer: ByteBuffer = ByteBuffer.allocateDirect(2 * 4).order(ByteOrder.nativeOrder())

    /// Drains one haptic queued this tick, or null when none remain. Call in a
    /// loop after tickLens and buzz the device for each.
    fun pullHaptic(): Haptic? {
        if (Gosslens.nativePullHaptic(handle, hapticBuffer) != 0) return null
        hapticBuffer.rewind()
        val fb = hapticBuffer.asFloatBuffer()
        return Haptic(fb.get(0).toInt(), fb.get(1))
    }
    fun grab(x: Float, y: Float, z: Float): Boolean = Gosslens.nativeGrab(handle, x, y, z) == 0
    fun release(): Boolean = Gosslens.nativeRelease(handle) == 0
    fun addCollider(x: Float, y: Float, z: Float): Boolean = Gosslens.nativeAddCollider(handle, x, y, z) == 0
    fun eraseCollider(x: Float, y: Float, z: Float, radius: Float): Boolean = Gosslens.nativeEraseCollider(handle, x, y, z, radius) == 0

    /** Releases one solver hair by the id the physics world assigned it,
     * pairing the acquire a hair lens performs at activation, so a hair
     * can retire mid-session without tearing the physics world down. */
    fun physicsHairRemove(hairId: Int): Boolean = Gosslens.nativePhysicsHairRemove(handle, hairId) == 0

    /** Pulls the finished brush ribbon (x, y, r, g, b, a per vertex) for the renderer. */
    fun brushVertices(): FloatArray {
        val count = Gosslens.nativeBrushVertexCount(handle)
        if (count <= 0) return FloatArray(0)
        val buffer = stage(count * 4)
        val written = Gosslens.nativeBrushVertices(handle, buffer, count)
        if (written <= 0) return FloatArray(0)
        val out = FloatArray(written)
        buffer.asFloatBuffer().get(out)
        return out
    }

    fun submitHardwareBuffer(
        buffer: android.hardware.HardwareBuffer,
        width: Int,
        height: Int,
        rotationDegrees: Int,
        mirrored: Boolean,
        colorStandard: Int = Gosslens.COLOR_BT709,
        colorRange: Int = Gosslens.RANGE_VIDEO,
        timestampUs: Long,
    ): Boolean = Gosslens.nativeSubmitHardwareBuffer(
        handle, buffer, width, height,
        Gosslens.flagsFor(rotationDegrees, mirrored),
        colorStandard, colorRange, timestampUs,
    ) == 0

    override fun close() {
        if (closed) return
        closed = true
        if (cleanable != null) NativeCleaner.disarm(cleanable) else Gosslens.nativeSessionDestroy(handle)
    }
}
