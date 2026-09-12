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
    /// Held strongly, and readable by the extensions: the engine report is an
    /// engine-level call a session is the natural place to reach.
    let engine: GossEngine
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
    /// A named composite source's frame straight from a platform buffer. Apple
    /// has no AHardwareBuffer, so this reports false there; the source path for
    /// this platform is submitSourceFrame with a Metal texture.
    public func submitSourceHardwareBuffer(name: String, desc: GossFrameDesc, hardwareBuffer: UnsafeMutableRawPointer) -> Bool {
        var raw = desc.raw
        return name.withCString { cName in
            goss_session_submit_source_hardware_buffer(handle, UnsafeRawPointer(cName).assumingMemoryBound(to: UInt8.self), strlen(cName), &raw, hardwareBuffer) == GOSS_OK
        }
    }

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

    /// The platform's current thermal pressure, mapped onto the engine's
    /// four states. Read it once per frame and pass it to reportFrame: the
    /// engine can measure a frame period on its own but has no way to reach
    /// this.
    public static var platformThermal: GossThermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// Reports one finished frame with the platform's thermal state read
    /// here, the call a frame loop wants.
    @discardableResult
    public func reportFrame(frameTimeUs: UInt32) -> GossDegradeLevel {
        reportFrame(frameTimeUs: frameTimeUs, thermal: GossSession.platformThermal)
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

    /// Submits a bare camera pose and projection, for a host driving a scan without a platform
    /// world session behind it: a selfie scan on the front camera, where the depth comes from a
    /// lens's own net rather than a sensor. Both matrices are column-major, sixteen floats.
    public func submitCameraPose(worldFromCamera: [Float], projection: [Float], timestampUs: Int64) {
        guard worldFromCamera.count == 16, projection.count == 16 else { return }
        var state = goss_world_state()
        state.tracking_state = 2
        state.timestamp_us = timestampUs
        withUnsafeMutablePointer(to: &state.world_from_camera) { pose in
            pose.withMemoryRebound(to: Float.self, capacity: 16) { out in
                for i in 0 ..< 16 { out[i] = worldFromCamera[i] }
            }
        }
        withUnsafeMutablePointer(to: &state.projection) { proj in
            proj.withMemoryRebound(to: Float.self, capacity: 16) { out in
                for i in 0 ..< 16 { out[i] = projection[i] }
            }
        }
        var light = goss_world_light(ambient_intensity: 1000, color_temperature_kelvin: 6500)
        _ = goss_session_submit_world(handle, &state, nil, 0, nil, 0, &light)
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

    /// A walkable route over the submitted world mesh, so an agent walks content
    /// across real scanned ground. Nil when no mesh is submitted or no route exists.
    public func pathAcrossWorld(start: SIMD3<Float>, goal: SIMD3<Float>) -> [SIMD3<Float>]? {
        var a = start
        var b = goal
        var found = 0
        var points = [Float](repeating: 0, count: 3 * 256)
        let status = withUnsafePointer(to: &a) { ap in ap.withMemoryRebound(to: Float.self, capacity: 3) { afp in
            withUnsafePointer(to: &b) { bp in bp.withMemoryRebound(to: Float.self, capacity: 3) { bfp in
                goss_session_path_across_world(handle, afp, bfp, &points, 256, &found)
            } }
        } }
        guard status == GOSS_OK else { return nil }
        return (0..<min(found, 256)).map { SIMD3(points[$0 * 3], points[$0 * 3 + 1], points[$0 * 3 + 2]) }
    }

    /// What a submitted plane is, as a named kind rather than the platform's own
    /// number, and whether a thing can rest on it.
    public enum PlaneKind: UInt32 {
        case unknown = 0, floor = 1, wall = 2, ceiling = 3, table = 4, seat = 5, door = 6, window = 7, screen = 8
    }

    public func planeKind(planeID: UInt64) -> (kind: PlaneKind, bearing: Bool)? {
        var kind: UInt32 = 0
        var bearing: UInt32 = 0
        guard goss_session_plane_kind(handle, planeID, &kind, &bearing) == GOSS_OK else { return nil }
        return (PlaneKind(rawValue: kind) ?? .unknown, bearing == 1)
    }

    /// The plane this session would call the floor: the lowest bearing surface it
    /// has been shown, or nil when it has been shown none.
    public func floorPlaneID() -> UInt64? {
        var id: UInt64 = 0
        guard goss_session_floor_plane(handle, &id) == GOSS_OK else { return nil }
        return id
    }

    /// Something already on a plane, so a placement answers about the surface as
    /// it is now rather than as it was detected.
    public struct Occupant {
        public let planeID: UInt64
        public let x: Float
        public let z: Float
        public let width: Float
        public let depth: Float

        public init(planeID: UInt64, x: Float, z: Float, width: Float, depth: Float) {
            self.planeID = planeID
            self.x = x
            self.z = z
            self.width = width
            self.depth = depth
        }
    }

    public struct Placement {
        public let planeID: UInt64
        public let position: SIMD3<Float>
        /// How much of the plane is still free afterwards, as a fraction.
        public let freeFraction: Float
    }

    /// Where this footprint fits, best surface first: the bearing plane with the
    /// most room left afterwards. An empty array is an answer.
    public func placeOn(width: Float, depth: Float, height: Float = 0, occupants: [Occupant] = []) -> [Placement] {
        var item = goss_footprint(width: width, depth: depth, height: height)
        var taken = occupants.map {
            goss_occupant(plane_id: $0.planeID, x: $0.x, z: $0.z, width: $0.width, depth: $0.depth)
        }
        var found = 0
        var out = [goss_placement](repeating: goss_placement(), count: 32)
        let status = goss_session_place_on(handle, &item, taken.isEmpty ? nil : &taken, taken.count, &out, out.count, &found)
        guard status == GOSS_OK || status == GOSS_AGAIN else { return [] }
        return out.prefix(min(found, out.count)).map {
            Placement(planeID: $0.plane_id, position: SIMD3($0.position.0, $0.position.1, $0.position.2), freeFraction: $0.free_fraction)
        }
    }

    /// Point to point in metres with its uncertainty. `known` is false when either
    /// end vouched for no accuracy, so a sigma of zero is never read as certainty.
    public func measure(from: SIMD3<Float>, fromAccuracyM: Float = 0, to: SIMD3<Float>, toAccuracyM: Float = 0) -> (metres: Float, sigma: Float, known: Bool)? {
        var a = from
        var b = to
        var metres: Float = 0
        var sigma: Float = 0
        var known: UInt32 = 0
        let ok = withUnsafePointer(to: &a) { ap in ap.withMemoryRebound(to: Float.self, capacity: 3) { afp in
            withUnsafePointer(to: &b) { bp in bp.withMemoryRebound(to: Float.self, capacity: 3) { bfp in
                goss_session_measure_between(handle, afp, fromAccuracyM, bfp, toAccuracyM, &metres, &sigma, &known) == GOSS_OK
            } }
        } }
        return ok ? (metres, sigma, known == 1) : nil
    }

    /// One landmark as it crosses to another device. No pose: a pose means nothing
    /// in another origin.
    public struct SharedLandmark {
        public let id: UInt64
        public let position: SIMD3<Float>
        public let confidence: Float

        public init(id: UInt64, position: SIMD3<Float>, confidence: Float = 1) {
            self.id = id
            self.position = position
            self.confidence = confidence
        }
    }

    /// What this device can offer another: one landmark per world anchor it holds.
    public func sharedLandmarks() -> [SharedLandmark] {
        var found = 0
        var out = [goss_shared_landmark](repeating: goss_shared_landmark(), count: 32)
        let status = goss_session_shared_landmarks(handle, &out, out.count, &found)
        guard status == GOSS_OK || status == GOSS_AGAIN else { return [] }
        return out.prefix(min(found, out.count)).map {
            SharedLandmark(id: $0.id, position: SIMD3($0.x, $0.y, $0.z), confidence: $0.confidence)
        }
    }

    /// The transform from the sender's origin into this one, column-major, with the
    /// fit it achieved. Nil when fewer than three landmarks matched, which cannot
    /// fix a rigid transform.
    public func alignShared(_ theirs: [SharedLandmark]) -> (transform: [Float], rmsError: Float, matched: UInt32)? {
        var list = theirs.map {
            goss_shared_landmark(id: $0.id, x: $0.position.x, y: $0.position.y, z: $0.position.z, confidence: $0.confidence)
        }
        var transform = [Float](repeating: 0, count: 16)
        var rms: Float = 0
        var matched: UInt32 = 0
        let ok = goss_session_align_shared(handle, list.isEmpty ? nil : &list, list.count, &transform, &rms, &matched) == GOSS_OK
        return ok ? (transform, rms, matched) : nil
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

    // MARK: - Clips

    /// Opens a clip as a source of frames for this session. The engine decodes it
    /// and this session decides when each frame lands, so the graph is driven by
    /// the clip rather than the clip decorating a camera feed.
    public func openClip(path: String) throws -> UInt32 {
        let bytes = Array(path.utf8)
        var clip: UInt32 = 0
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_session_open_clip(handle, buffer.baseAddress, buffer.count, &clip))
        }
        return clip
    }

    /// Decodes the clip's next frame and submits it as this session's frame.
    /// Returns false at the end of the stream, where a caller loops by seeking.
    /// Pass 0 to carry the clip's own presentation time.
    @discardableResult
    public func clipSubmitFrame(_ clip: UInt32, timestampUs: Int64 = 0) throws -> Bool {
        let raw = goss_session_clip_submit_frame(handle, clip, timestampUs)
        if raw == GOSS_AGAIN { return false }
        try checked(raw)
        return true
    }

    /// The keyframe at or before a time. Throws past the end rather than clamping.
    public func clipSeek(_ clip: UInt32, targetUs: Int64) throws {
        try checked(goss_session_clip_seek(handle, clip, targetUs))
    }

    public func clipInfo(_ clip: UInt32) throws -> GossClipInfo {
        var raw = goss_clip_info()
        try checked(goss_session_clip_info(handle, clip, &raw))
        return GossClipInfo(raw)
    }

    public func closeClip(_ clip: UInt32) throws {
        try checked(goss_session_close_clip(handle, clip))
    }

    /// Moves by whole frames and leaves the clip on the one it lands on. Forward
    /// decodes; backward seeks and decodes, because a forward-only decoder cannot
    /// step back any other way.
    public func clipStep(_ clip: UInt32, frames: Int32) throws {
        try checked(goss_session_clip_step(handle, clip, frames))
    }

    // MARK: - Perception

    /// Every section this build writes, asked of the engine rather than assumed: a
    /// hand-written mask excluded the embedding section the day it was added.
    public static var selectAll: UInt32 { goss_perception_select_all() }

    /// One versioned record of what the engine currently sees. Every section
    /// carries its own tag, version and byte length, so a consumer built against
    /// an older schema steps over what it does not know. Sized in one retry.
    public func perceptionSnapshot(select: UInt32 = GossSession.selectAll) throws -> [UInt8] {
        var needed = 0
        var probe: [UInt8] = []
        let first = goss_session_perception_snapshot(handle, select, nil, 0, &needed)
        if first != GOSS_OK && first != GOSS_AGAIN { try checked(first) }
        guard needed > 0 else { return [] }
        probe = [UInt8](repeating: 0, count: needed)
        var written = 0
        try probe.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_perception_snapshot(handle, select, buffer.baseAddress, buffer.count, &written))
        }
        return Array(probe[0..<written])
    }

    /// The same record as compact JSON, for a gateway that speaks it.
    public func perceptionJson(select: UInt32 = GossSession.selectAll) throws -> String {
        var needed = 0
        let first = goss_session_perception_json(handle, select, nil, 0, &needed)
        if first != GOSS_OK && first != GOSS_AGAIN { try checked(first) }
        guard needed > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: needed)
        var written = 0
        try buffer.withUnsafeMutableBufferPointer { p in
            try checked(goss_session_perception_json(handle, select, p.baseAddress, p.count, &written))
        }
        return String(decoding: buffer[0..<written], as: UTF8.self)
    }

    /// Drains the session's event ring in order. `dropped` says whether anything
    /// was missed since the last drain, and is cleared by the read, so a caller
    /// sees each drop once rather than the same number for ever.
    public func pollEvents(capacity: Int = 64) throws -> (events: [GossEvent], dropped: UInt64) {
        var raw = [goss_event](repeating: goss_event(), count: capacity)
        var count: UInt32 = 0
        var dropped: UInt64 = 0
        try raw.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_poll_events(handle, buffer.baseAddress, UInt32(capacity), &count, &dropped))
        }
        return (raw.prefix(Int(count)).map(GossEvent.init), dropped)
    }

    // MARK: - Screens

    /// Opens a screen as a source. A scale of zero takes the surface's own, which
    /// is what you want unless you are deliberately capturing small.
    public func openScreen(surfaceId: UInt64, scale: Float = 0) throws -> UInt32 {
        var screen: UInt32 = 0
        try checked(goss_session_open_screen(handle, surfaceId, scale, &screen))
        return screen
    }

    public func closeScreen(_ screen: UInt32) throws {
        try checked(goss_session_close_screen(handle, screen))
    }

    /// Submits the newest frame under a source name. Answers false when the
    /// screen has not changed, so a still desktop costs nothing.
    public func stepScreen(_ screen: UInt32, source: String = "") -> Bool {
        let bytes = Array(source.utf8)
        if bytes.isEmpty {
            return goss_session_step_screen(handle, screen, nil, 0) == GOSS_OK
        }
        return bytes.withUnsafeBufferPointer { buffer in
            goss_session_step_screen(handle, screen, buffer.baseAddress, bytes.count) == GOSS_OK
        }
    }

    /// Where a normalized point lands: the surface's logical points, its backing
    /// pixels, and the desktop.
    public func screenPoint(_ screen: UInt32, x: Float, y: Float) throws -> (logical: (Float, Float), pixel: (Float, Float), desktop: (Float, Float)) {
        var logical = [Float](repeating: 0, count: 2)
        var pixel = [Float](repeating: 0, count: 2)
        var desktop = [Float](repeating: 0, count: 2)
        try checked(goss_session_screen_point(handle, screen, x, y, &logical, &pixel, &desktop))
        return ((logical[0], logical[1]), (pixel[0], pixel[1]), (desktop[0], desktop[1]))
    }

    // MARK: - Scope

    /// Narrows what this session answers. A session opens fully permissive; a
    /// read out of scope is dropped from the record rather than failing, and a
    /// verb out of scope is refused.
    public func setScope(sections: UInt32, verbs: UInt32) throws {
        try checked(goss_session_set_scope(handle, sections, verbs))
    }

    public func scope() throws -> (sections: UInt32, verbs: UInt32) {
        var sections: UInt32 = 0
        var verbs: UInt32 = 0
        try checked(goss_session_scope(handle, &sections, &verbs))
        return (sections, verbs)
    }

    // MARK: - Memory

    /// Opens the memory plane. Nothing is remembered until this is called, and
    /// the bound is yours, so the memory you were promised is the memory you get.
    public func memoryOpen(dim: UInt32, maxEntries: UInt32 = 4096) throws {
        try checked(goss_session_memory_open(handle, dim, maxEntries))
    }

    public func memoryClose() throws {
        try checked(goss_session_memory_close(handle))
    }

    /// Remembers one embedding. The same id replaces rather than duplicating, so
    /// a keyframe corrected later does not leave the earlier one to be found.
    public func remember(id: UInt64, embedding: [Float]) throws {
        try embedding.withUnsafeBufferPointer { buffer in
            try checked(goss_session_memory_remember(handle, id, buffer.baseAddress, UInt32(embedding.count)))
        }
    }

    public func forget(id: UInt64) throws {
        try checked(goss_session_memory_forget(handle, id))
    }

    /// The nearest remembered embeddings, fewest-first by distance. Fewer than k
    /// on a memory smaller than k rather than padded with nothing.
    public func memorySearch(_ query: [Float], k: UInt32 = 8) throws -> [(id: UInt64, score: Float)] {
        var ids = [UInt64](repeating: 0, count: Int(k))
        var scores = [Float](repeating: 0, count: Int(k))
        var count: UInt32 = 0
        try query.withUnsafeBufferPointer { q in
            try ids.withUnsafeMutableBufferPointer { idBuf in
                try scores.withUnsafeMutableBufferPointer { scoreBuf in
                    try checked(goss_session_memory_search(handle, q.baseAddress, UInt32(query.count), k, idBuf.baseAddress, scoreBuf.baseAddress, &count))
                }
            }
        }
        return (0..<Int(count)).map { (id: ids[$0], score: scores[$0]) }
    }

    public func memoryStats() throws -> (count: UInt32, bytes: UInt64) {
        var live: UInt32 = 0
        var bytes: UInt64 = 0
        try checked(goss_session_memory_stats(handle, &live, &bytes))
        return (live, bytes)
    }

    /// The whole memory as bytes, so a cold start is instant.
    public func memorySave() throws -> [UInt8] {
        var needed = 0
        _ = goss_session_memory_save(handle, nil, 0, &needed)
        guard needed > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: needed)
        try out.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_memory_save(handle, buffer.baseAddress, needed, &needed))
        }
        return out
    }

    /// The memory sealed under a host key. The nonce is yours: reusing one under
    /// the same key breaks the cipher, and only you know what you have written.
    public func memorySaveSealed(key: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        var needed = 0
        try key.withUnsafeBufferPointer { k in
            try nonce.withUnsafeBufferPointer { n in
                _ = goss_session_memory_save_sealed(handle, k.baseAddress, n.baseAddress, nil, 0, &needed)
                return
            }
        }
        guard needed > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: needed)
        try key.withUnsafeBufferPointer { k in
            try nonce.withUnsafeBufferPointer { n in
                try out.withUnsafeMutableBufferPointer { buffer in
                    try checked(goss_session_memory_save_sealed(handle, k.baseAddress, n.baseAddress, buffer.baseAddress, needed, &needed))
                }
            }
        }
        return out
    }

    public func memoryLoadSealed(key: [UInt8], bytes: [UInt8]) throws {
        try key.withUnsafeBufferPointer { k in
            try bytes.withUnsafeBufferPointer { b in
                try checked(goss_session_memory_load_sealed(handle, k.baseAddress, b.baseAddress, bytes.count))
            }
        }
    }

    public func memoryLoad(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_session_memory_load(handle, buffer.baseAddress, bytes.count))
        }
    }

    // MARK: - Text

    /// Turns on the text rail. A detector alone finds where the text is, which
    /// is what a redaction or a rectified crop needs; pass a recogniser and its
    /// dictionary to get strings back.
    public func enableText(detector: [UInt8], recognizer: [UInt8] = [], dictionary: [UInt8] = [], detectSide: UInt32 = 320) throws {
        try detector.withUnsafeBufferPointer { det in
            try recognizer.withUnsafeBufferPointer { rec in
                try dictionary.withUnsafeBufferPointer { dict in
                    try checked(goss_session_enable_text(
                        handle,
                        det.baseAddress, detector.count,
                        rec.baseAddress, recognizer.count,
                        dict.baseAddress, dictionary.count,
                        detectSide
                    ))
                }
            }
        }
    }

    public func disableText() throws {
        try checked(goss_session_disable_text(handle))
    }

    /// How many readings the frame holds and how many the bound turned away,
    /// which is what tells a caller it is losing readings rather than seeing
    /// them all.
    public func textCount() throws -> (live: UInt32, refused: UInt64) {
        var live: UInt32 = 0
        var refused: UInt64 = 0
        try checked(goss_session_text_count(handle, &live, &refused))
        return (live, refused)
    }

    /// Everything the frame says, each reading with its quadrilateral and the
    /// string itself.
    public func readings() throws -> [GossReading] {
        let counts = try textCount()
        var out: [GossReading] = []
        out.reserveCapacity(Int(counts.live))
        for index in 0..<counts.live {
            var raw = goss_text_entry()
            try checked(goss_session_text_at(handle, index, &raw))
            var needed = 0
            _ = goss_session_text_string(handle, index, nil, 0, &needed)
            var text = ""
            if needed > 0 {
                var bytes = [UInt8](repeating: 0, count: needed)
                let status = bytes.withUnsafeMutableBufferPointer { buffer in
                    goss_session_text_string(handle, index, buffer.baseAddress, needed, &needed)
                }
                if status == GOSS_OK { text = String(decoding: bytes, as: UTF8.self) }
            }
            out.append(GossReading(raw: raw, text: text))
        }
        return out
    }

    // MARK: - Annotations

    /// Adds or updates one annotation. The same id replaces rather than
    /// duplicating, so moving one box every frame leaks no entry per frame.
    public func annotate(_ annotation: GossAnnotation, text: String = "") throws {
        var raw = annotation.raw
        let bytes = Array(text.utf8)
        if bytes.isEmpty {
            try checked(goss_session_annotate(handle, &raw, nil, 0))
        } else {
            try bytes.withUnsafeBufferPointer { buffer in
                try checked(goss_session_annotate(handle, &raw, buffer.baseAddress, buffer.count))
            }
        }
    }

    public func annotationRemove(_ id: UInt32) throws {
        try checked(goss_session_annotation_remove(handle, id))
    }

    public func annotationClear() throws {
        try checked(goss_session_annotation_clear(handle))
    }

    /// Live count and how many adds the bound turned away, which is what tells a
    /// caller its overlay is losing annotations rather than drawing them out of
    /// sight.
    public func annotationCount() throws -> (live: UInt32, refused: UInt64) {
        var live: UInt32 = 0
        var refused: UInt64 = 0
        try checked(goss_session_annotation_count(handle, &live, &refused))
        return (live, refused)
    }

    // MARK: - Egress

    /// Installs the egress policy: what the brain sees and what it costs. Throws
    /// on a configuration outside its own ranges rather than producing a stream
    /// nobody can explain.
    public func egressConfigure(_ config: GossEgressConfig) throws {
        var raw = config.raw
        try checked(goss_session_egress_configure(handle, &raw))
    }

    /// One frame, whatever the change score says.
    public func egressRequest() throws {
        try checked(goss_session_egress_request(handle))
    }

    /// Whether this frame is worth sending and why. Nil when there are no pixels
    /// to score, which is not a failure: a frame nobody can score is not one to
    /// send on a change trigger.
    public func egressDecide() throws -> GossEgressDecision? {
        var raw = goss_egress_decision()
        let status = goss_session_egress_decide(handle, &raw)
        if status == GOSS_AGAIN { return nil }
        try checked(status)
        return GossEgressDecision(raw)
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
