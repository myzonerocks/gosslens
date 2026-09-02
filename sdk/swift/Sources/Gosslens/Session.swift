import CGosslens
import Foundation

/// Whole-pipeline frame budget; zero means the built-in default (30 fps).
public struct GossSessionConfig {
    public var frameBudgetUs: UInt32

    public init(frameBudgetUs: UInt32 = 0) {
        self.frameBudgetUs = frameBudgetUs
    }
}

/// Per-preview runtime: frame submission, beauty, tracking, telemetry.
/// Confined to the graph thread, same as GossEngine - unchecked for the
/// same reason (see GossEngine's own note).
public final class GossSession: @unchecked Sendable {
    let handle: OpaquePointer
    /// A live session dereferences engine state (gpa, renderer, recording)
    /// on every call and at destroy, so it holds the engine strongly: ARC
    /// cannot deinit the engine while any session is still alive, which
    /// keeps goss_session_destroy ordered before goss_engine_destroy.
    private let engine: GossEngine
    private var destroyed = false

    // Grow-only scratch for the per-frame multi-face and multi-body
    // submits, so the hot path copies without allocating.
    var faceSubmitScratch: [goss_face_result] = []
    var bodySubmitScratch: [goss_pose_result] = []

    public static func create(engine: GossEngine, config: GossSessionConfig = GossSessionConfig()) throws -> GossSession {
        var raw = goss_session_config(frame_budget_us: config.frameBudgetUs, reserved: 0)
        var handle: OpaquePointer?
        try checked(goss_session_create(engine.handle, &raw, &handle))
        guard let handle else { throw GossStatus.outOfMemory }
        return GossSession(engine: engine, handle: handle)
    }

    private init(engine: GossEngine, handle: OpaquePointer) {
        self.engine = engine
        self.handle = handle
    }

    deinit {
        if !destroyed { goss_session_destroy(handle) }
    }

    /// Safe to call more than once; only the first call reaches the ABI -
    /// deinit falls back to this same destroy for callers who never call
    /// it explicitly, and must not double-free a handle this already did.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        goss_session_destroy(handle)
    }

    // MARK: - Frame submission

    /// Zero-copy: hands over up to three platform texture handles
    /// (MTLTexture and friends) as opaque pointer-sized values. The
    /// platform object must outlive the next rendered frame.
    public func submitFrame(desc: GossFrameDesc, planes: [UInt64]) throws {
        var raw = desc.raw
        let p0 = planes.count > 0 ? planes[0] : 0
        let p1 = planes.count > 1 ? planes[1] : 0
        let p2 = planes.count > 2 ? planes[2] : 0
        var framePlanes = goss_frame_planes(plane_count: UInt32(planes.count), reserved: 0, planes: (p0, p1, p2))
        try checked(goss_session_submit_frame(handle, &raw, &framePlanes))
    }

    /// The CPU-copy path: copies NV12 planes into pooled textures.
    /// colorStandard/colorRange default to the common camera case
    /// (BT.709, video range); a debug/test corpus decoded at a
    /// different standard passes its own.
    public func submitFrameCopy(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, rotationDegrees: UInt32, mirrored: Bool, colorStandard: GossColorStandard = .bt709, colorRange: GossColorRange = .video, timestampUs: Int64) throws {
        var raw = GossFrameDesc(width: width, height: height, pixelFormat: .nv12, colorStandard: colorStandard, colorRange: colorRange, rotationDegrees: rotationDegrees, mirrored: mirrored, timestampUs: timestampUs).raw
        try checked(goss_session_submit_frame_copy(handle, &raw, y, yStride, uv, uvStride))
    }

    /// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a canvas
    /// or video element's own byte buffer.
    public func submitFrameRgbaCopy(rgba: UnsafePointer<UInt8>, stride: UInt32, width: UInt32, height: UInt32, pixelFormat: GossPixelFormat = .rgba8, rotationDegrees: UInt32 = 0, mirrored: Bool = false, timestampUs: Int64 = 0) throws {
        var raw = GossFrameDesc(width: width, height: height, pixelFormat: pixelFormat, rotationDegrees: rotationDegrees, mirrored: mirrored, timestampUs: timestampUs).raw
        try checked(goss_session_submit_frame_rgba_copy(handle, &raw, rgba, stride))
    }

    /// Submits one exposure of an HDR bracket, fed only to bracket-source
    /// temporal.fuse nodes (the live camera feeds the rest); the fusion
    /// publishes once the ring holds a full bracket.
    public func submitFrameBracket(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, colorStandard: GossColorStandard = .bt709, colorRange: GossColorRange = .video) throws {
        var raw = GossFrameDesc(width: width, height: height, pixelFormat: .nv12, colorStandard: colorStandard, colorRange: colorRange, rotationDegrees: 0, mirrored: false, timestampUs: 0).raw
        try checked(goss_session_submit_frame_bracket(handle, &raw, y, yStride, uv, uvStride))
    }

    /// Submits one RGBA exposure of an HDR bracket, converted to NV12 and fed to
    /// bracket-source temporal.fuse nodes.
    public func submitFrameBracketRgba(_ rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try rgba.withUnsafeBufferPointer { buf in
            try checked(goss_session_submit_frame_bracket_rgba(handle, buf.baseAddress, width, height))
        }
    }

    /// Zero-copy submission of a platform hardware buffer (an AHardwareBuffer
    /// on Android); hardwareBuffer is the opaque platform handle. False means
    /// the buffer could not be imported, the signal to fall back to
    /// submitFrameCopy for this stream.
    public func submitHardwareBuffer(desc: GossFrameDesc, hardwareBuffer: UnsafeMutableRawPointer) -> Bool {
        var raw = desc.raw
        return goss_session_submit_hardware_buffer(handle, &raw, hardwareBuffer) == GOSS_OK
    }

    // MARK: - Telemetry

    /// Reports one finished frame: measured whole-pipeline time plus
    /// current thermal pressure. Returns the degradation level in
    /// effect for the next frame.
    @discardableResult
    public func reportFrame(frameTimeUs: UInt32, thermal: GossThermal) -> GossDegradeLevel {
        let raw = goss_session_report_frame(handle, frameTimeUs, goss_thermal(rawValue: thermal.rawValue))
        return GossDegradeLevel(rawValue: raw.rawValue) ?? .passthrough
    }

    // MARK: - Face tracking

    public func enableFaceTracking(taskBundle: Data, threads: Int32) throws {
        try taskBundle.withUnsafeBytes { buffer in
            try checked(goss_session_enable_face_tracking(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disableFaceTracking() {
        goss_session_disable_face_tracking(handle)
    }

    /// Stands the hand tracking worker up from a hand landmarker or
    /// gesture recognizer task bundle; up to two hands publish per
    /// frame, with canned gestures scored when the bundle carries them.
    public func enableHandTracking(taskBundle: Data, threads: Int32) throws {
        try taskBundle.withUnsafeBytes { buffer in
            try checked(goss_session_enable_hand_tracking(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disableHandTracking() {
        goss_session_disable_hand_tracking(handle)
    }

    /// Stands the pose tracking worker up from a pose landmarker task
    /// bundle; one 33-point body publishes per frame.
    public func enablePoseTracking(taskBundle: Data, threads: Int32) throws {
        try taskBundle.withUnsafeBytes { buffer in
            try checked(goss_session_enable_pose_tracking(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disablePoseTracking() {
        goss_session_disable_pose_tracking(handle)
    }

    /// Upper-body pose mode. While enabled, the tracked pose reports only the
    /// upper body; the lower-body joints (knees down) read absent.
    public func setPoseUpperBody(_ enabled: Bool) throws {
        try checked(goss_session_set_pose_upper_body(handle, enabled ? 1 : 0))
    }

    /// Raycasts a normalized screen point (0..1, origin top-left) against the
    /// tracked ground plane, returning the world hit position. Nil until world
    /// tracking is live and the ray meets the plane, so a tap-to-place lens
    /// polls it and drops an anchor at the hit.
    public func hitTest(screenX: Float, screenY: Float) -> SIMD3<Float>? {
        var out = SIMD3<Float>(0, 0, 0)
        let ok = withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: Float.self, capacity: 3) { fp in
                goss_session_hit_test(handle, screenX, screenY, fp) == GOSS_OK
            }
        }
        return ok ? out : nil
    }

    /// Submits the device's pre-scanned world mesh (scene reconstruction, a VPS
    /// scan) in world space: `vertices` are xyz triples and `indices` name three
    /// vertices per triangle. Passing empty arrays clears the stored mesh.
    public func submitWorldMesh(vertices: [Float], indices: [UInt32]) {
        _ = goss_session_submit_world_mesh(handle, vertices, vertices.count / 3, indices, indices.count)
    }

    /// Casts a world-space ray against the submitted world mesh, returning the
    /// nearest surface hit position and its ray distance, or nil when no mesh is
    /// submitted or the ray misses. A tap-to-place lens anchors content there.
    public func raycastWorldMesh(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (point: SIMD3<Float>, distance: Float)? {
        var o = origin
        var d = direction
        var point = SIMD3<Float>(0, 0, 0)
        var distance: Float = 0
        let ok = withUnsafePointer(to: &o) { op in op.withMemoryRebound(to: Float.self, capacity: 3) { ofp in
            withUnsafePointer(to: &d) { dp in dp.withMemoryRebound(to: Float.self, capacity: 3) { dfp in
                withUnsafeMutablePointer(to: &point) { pp in pp.withMemoryRebound(to: Float.self, capacity: 3) { pfp in
                    goss_session_raycast_world_mesh(handle, ofp, dfp, pfp, &distance) == GOSS_OK
                } }
            } }
        } }
        return ok ? (point, distance) : nil
    }

    /// The stable track id of the index-th face, an integer that stays with the
    /// same person across frames as the submission order shuffles, or nil once
    /// index reaches the face count.
    public func faceTrackId(index: UInt32) -> UInt32? {
        var out: UInt32 = 0
        let ok = goss_session_face_track_id(handle, index, &out) == GOSS_OK
        return ok ? out : nil
    }

    /// Stands the segmentation worker up from a raw selfie or hair segmenter
    /// .tflite model (not bundled the way a face_landmarker.task is). The
    /// bytes are copied; the caller may release them on return. Throws
    /// .unsupported on builds without the inference stack.
    public func enableSegmentation(model: Data, threads: Int32) throws {
        try model.withUnsafeBytes { buffer in
            try checked(goss_session_enable_segmentation(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disableSegmentation() {
        goss_session_disable_segmentation(handle)
    }

    /// Allowlists a bring-your-own model by its 32-byte SHA-256 digest, so a net
    /// whose digest is not listed is refused when a tracker or segmenter is
    /// enabled. With none set, any model loads. Call before enabling the worker.
    public func allowModelDigest(_ digest: [UInt8]) throws {
        precondition(digest.count == 32, "a model digest is 32 bytes")
        try digest.withUnsafeBufferPointer { buffer in
            try checked(goss_session_allow_model_digest(handle, buffer.baseAddress))
        }
    }

    /// Clears the model allowlist; with none set, any model loads again.
    public func clearModelAllowlist() throws {
        try checked(goss_session_clear_model_allowlist(handle))
    }

    public func trackFrame(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, colorStandard: GossColorStandard = .bt709, colorRange: GossColorRange = .video, timestampUs: Int64) throws {
        var raw = GossFrameDesc(width: width, height: height, pixelFormat: .nv12, colorStandard: colorStandard, colorRange: colorRange, timestampUs: timestampUs).raw
        try checked(goss_session_track_frame(handle, &raw, y, yStride, uv, uvStride))
    }

    /// Runs each selfie-source splat.cloud once over one still, so a photoreal
    /// avatar is generated from a photo and then held off the live camera.
    public func submitAvatarSource(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, colorStandard: GossColorStandard = .bt709, colorRange: GossColorRange = .video, timestampUs: Int64) throws {
        var raw = GossFrameDesc(width: width, height: height, pixelFormat: .nv12, colorStandard: colorStandard, colorRange: colorRange, timestampUs: timestampUs).raw
        try checked(goss_session_submit_avatar_source(handle, &raw, y, yStride, uv, uvStride))
    }

    /// The RGBA sibling of submitAvatarSource: runs each selfie-source splat
    /// once over one single-plane RGBA8 still (a canvas or photo's own bytes).
    public func submitAvatarSourceRgba(rgba: UnsafePointer<UInt8>, width: UInt32, height: UInt32) throws {
        try checked(goss_session_submit_avatar_source_rgba(handle, rgba, width, height))
    }

    public func setFaceLandmarks(points: [Float]) throws {
        try points.withUnsafeBufferPointer { buffer in
            try checked(goss_session_set_face_landmarks(handle, buffer.baseAddress, UInt32(points.count / 3)))
        }
    }

    // MARK: - Beauty

    public func enableBeauty(resourceDir: String) throws {
        try checked(goss_session_enable_beauty(handle, resourceDir))
    }

    public func disableBeauty() {
        goss_session_disable_beauty(handle)
    }

    public func setBeauty(effect: Int32, amount: Float) throws {
        try checked(goss_session_set_beauty(handle, effect, amount))
    }

    public func setWhiten(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_WHITEN, amount: amount) }
    public func setSmooth(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_SMOOTH, amount: amount) }
    public func setThinFace(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_THIN_FACE, amount: amount) }
    public func setBigEye(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_BIG_EYE, amount: amount) }
    public func setLipstick(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_LIPSTICK, amount: amount) }
    public func setBlush(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_BLUSH, amount: amount) }

    /// Web only; throws .unsupported on every other target.
    public func setBeautyLut(slot: Int32, rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try checked(goss_session_set_beauty_lut(handle, slot, rgba, width, height))
    }

    /// Web only; throws .unsupported on every other target.
    public func setBeautyMakeupTexture(effect: Int32, rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try checked(goss_session_set_beauty_makeup_texture(handle, effect, rgba, width, height))
    }

    /// CPU beauty pass over one RGBA frame into a caller-owned output
    /// buffer, at least width * height * 4 bytes.
    public func beautifyFrame(rgbaIn: [UInt8], rgbaOut: inout [UInt8], width: UInt32, height: UInt32) throws {
        let bytes = Int(width) * Int(height) * 4
        guard rgbaIn.count >= bytes, rgbaOut.count >= bytes else { throw GossStatus.invalidArgument }
        try rgbaOut.withUnsafeMutableBufferPointer { out in
            try checked(goss_session_beautify_frame(handle, rgbaIn, width, height, out.baseAddress))
        }
    }
}
