import CGosslens

/// One reusable tracking readout. landmarks holds landmarkCount * 3
/// valid floats (x, y in frame pixels, z in the same scale); blendshapes
/// holds 52 scores in zero to one. landmarkCount zero means no face.
public final class GossFaceResult {
    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var presence: Float = 0
    public private(set) var landmarkCount: Int = 0
    public private(set) var landmarks: [Float]
    public private(set) var blendshapes: [Float]

    var raw = goss_face_result()

    public init() {
        landmarks = [Float](repeating: 0, count: Int(GOSS_FACE_LANDMARK_COUNT) * 3)
        blendshapes = [Float](repeating: 0, count: Int(GOSS_FACE_BLENDSHAPE_COUNT))
    }

    /// Lifts raw's fields into the preallocated arrays - no per-frame
    /// allocation as long as the caller reuses one instance.
    func parse() {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        presence = raw.presence
        landmarkCount = Int(raw.landmark_count)
        withUnsafeBytes(of: raw.landmarks) { source in
            landmarks.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
        withUnsafeBytes(of: raw.blendshapes) { source in
            blendshapes.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
    }
}

/// A canned gesture class, in the classifier's own label order. none is
/// also what a bundle without gesture models reports.
public enum GossGesture: UInt32 {
    case none = 0
    case closedFist = 1
    case openPalm = 2
    case pointingUp = 3
    case thumbDown = 4
    case thumbUp = 5
    case victory = 6
    case iLoveYou = 7
}

/// A named attach point on the tracked face mesh, for `faceRegion`. The
/// left/right labels are the subject's own.
public enum GossFaceRegion: UInt32 {
    case forehead = 0
    case glabella = 1
    case noseTip = 2
    case chin = 3
    case leftEye = 4
    case rightEye = 5
    case leftCheek = 6
    case rightCheek = 7
    case leftEar = 8
    case rightEar = 9
    case mouthCenter = 10
    case leftMouthCorner = 11
    case rightMouthCorner = 12
}

/// A named attach point on the tracked body skeleton, for `bodyJoint`. The
/// left/right labels are the subject's own.
public enum GossBodyJoint: UInt32 {
    case head = 0
    case leftShoulder = 1
    case rightShoulder = 2
    case leftElbow = 3
    case rightElbow = 4
    case leftWrist = 5
    case rightWrist = 6
    case leftHip = 7
    case rightHip = 8
    case leftKnee = 9
    case rightKnee = 10
    case leftAnkle = 11
    case rightAnkle = 12
}

/// A named attach point on a tracked hand, for `handJoint`. `palm` is the
/// middle-finger knuckle, a stable palm-centre proxy.
public enum GossHandJoint: UInt32 {
    case wrist = 0
    case thumbTip = 1
    case indexTip = 2
    case middleTip = 3
    case ringTip = 4
    case pinkyTip = 5
    case palm = 6
}

/// One reusable hand tracking readout, up to two hands per frame.
/// handedness is the model's score that the hand is a right hand; hand
/// h's point p sits at (h * landmarkCount + p) * 3 in landmarks.
public final class GossHandResult {
    public static let landmarkCount = Int(GOSS_HAND_LANDMARK_COUNT)
    public static let maxHands = Int(GOSS_HAND_MAX)

    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var handCount: Int = 0
    public private(set) var presences: [Float]
    public private(set) var handednesses: [Float]
    public private(set) var gestures: [GossGesture]
    public private(set) var gestureScores: [Float]
    public private(set) var landmarks: [Float]

    var raw = goss_hand_result()

    public init() {
        presences = [Float](repeating: 0, count: Self.maxHands)
        handednesses = [Float](repeating: 0, count: Self.maxHands)
        gestures = [GossGesture](repeating: .none, count: Self.maxHands)
        gestureScores = [Float](repeating: 0, count: Self.maxHands)
        landmarks = [Float](repeating: 0, count: Self.maxHands * Self.landmarkCount * 3)
    }

    /// Lifts raw's fields into the preallocated arrays - no per-frame
    /// allocation as long as the caller reuses one instance.
    func parse() {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        handCount = Int(raw.hand_count)
        let landmark_floats = Self.landmarkCount * 3
        withUnsafeBytes(of: raw.hands) { source in
            for at in 0 ..< Self.maxHands {
                let base = at * MemoryLayout<goss_hand>.stride
                presences[at] = source.loadUnaligned(fromByteOffset: base, as: Float.self)
                handednesses[at] = source.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                gestures[at] = GossGesture(rawValue: source.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)) ?? .none
                gestureScores[at] = source.loadUnaligned(fromByteOffset: base + 12, as: Float.self)
                landmarks.withUnsafeMutableBytes { dest in
                    dest.baseAddress!.advanced(by: at * landmark_floats * 4)
                        .copyMemory(from: source.baseAddress!.advanced(by: base + 16), byteCount: landmark_floats * 4)
                }
            }
        }
    }
}

/// One reusable pose tracking readout: a 33-point skeleton with
/// per-point visibility and presence scores.
public final class GossPoseResult {
    public static let landmarkCount = Int(GOSS_POSE_LANDMARK_COUNT)

    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var presence: Float = 0
    public private(set) var landmarkCount: Int = 0
    public private(set) var landmarks: [Float]
    public private(set) var visibilities: [Float]
    public private(set) var presences: [Float]

    var raw = goss_pose_result()

    public init() {
        landmarks = [Float](repeating: 0, count: Self.landmarkCount * 3)
        visibilities = [Float](repeating: 0, count: Self.landmarkCount)
        presences = [Float](repeating: 0, count: Self.landmarkCount)
    }

    /// Lifts raw's fields into the preallocated arrays - no per-frame
    /// allocation as long as the caller reuses one instance.
    func parse() {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        presence = raw.presence
        landmarkCount = Int(raw.landmark_count)
        withUnsafeBytes(of: raw.landmarks) { source in
            landmarks.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
        withUnsafeBytes(of: raw.visibilities) { source in
            visibilities.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
        withUnsafeBytes(of: raw.presences) { source in
            presences.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
    }
}

/// Tracking/telemetry readouts, reached directly off GossSession rather
/// than their own handle type.
extension GossSession {
    /// Fills result with the newest tracking output. Throws .again until
    /// the tracking worker has published its first result.
    public func faceResult(_ result: GossFaceResult) throws {
        try checked(goss_session_face_result(handle, &result.raw))
        result.parse()
    }

    /// Submits the faces tracked this frame for the multi-face path, so a
    /// lens can instance effects across every face and the face-anchor
    /// render fans out. An empty array clears the path back to the single
    /// internal tracker. Faces past GOSS_FACE_MAX are ignored.
    public func submitFaces(_ faces: [GossFaceResult]) throws {
        if faces.isEmpty {
            try checked(goss_session_submit_faces(handle, nil, 0))
            return
        }
        var raws = faces.map { $0.raw }
        try checked(goss_session_submit_faces(handle, &raws, UInt32(raws.count)))
    }

    /// The number of faces the last submitFaces kept, zero to GOSS_FACE_MAX.
    public func faceCount() throws -> Int {
        var count: UInt32 = 0
        try checked(goss_session_face_count(handle, &count))
        return Int(count)
    }

    /// Fills result with the index-th submitted face. Throws
    /// .invalidArgument once index reaches faceCount, so a caller loops zero
    /// to faceCount to visit every face.
    public func faceResult(at index: Int, into result: GossFaceResult) throws {
        try checked(goss_session_face_result_at(handle, UInt32(index), &result.raw))
        result.parse()
    }

    /// Submits the bodies tracked this frame for the multi-person path, so a
    /// lens can instance effects across every body. An empty array clears the
    /// path. Bodies past GOSS_BODY_MAX are ignored.
    public func submitBodies(_ bodies: [GossPoseResult]) throws {
        if bodies.isEmpty {
            try checked(goss_session_submit_bodies(handle, nil, 0))
            return
        }
        var raws = bodies.map { $0.raw }
        try checked(goss_session_submit_bodies(handle, &raws, UInt32(raws.count)))
    }

    /// Submits one frame's depth map from the host AR backend (ARKit scene
    /// depth): width by height metres per pixel, row major, with the near and
    /// far metres that bound it. An empty array clears it. Kept for depth
    /// occlusion against the rendered content.
    public func submitDepth(_ depth: [Float], width: UInt32, height: UInt32, near: Float, far: Float) throws {
        if depth.isEmpty {
            try checked(goss_session_submit_depth(handle, nil, 0, 0, 0, 0))
            return
        }
        try depth.withUnsafeBufferPointer { buf in
            try checked(goss_session_submit_depth(handle, buf.baseAddress, width, height, near, far))
        }
    }

    /// Submits the camera intrinsics an undistort.pass corrects for: the focal
    /// lengths and principal point in pixels of the submitted frame, and the
    /// radial distortion coefficients (k1, k2 read). An empty array or zero
    /// focal length clears them, leaving an undistort.pass inert.
    public func submitCameraIntrinsics(fx: Float, fy: Float, cx: Float, cy: Float, distortion: [Float]) throws {
        if distortion.isEmpty {
            try checked(goss_session_submit_camera_intrinsics(handle, 0, 0, 0, 0, nil, 0))
            return
        }
        try distortion.withUnsafeBufferPointer { buf in
            try checked(goss_session_submit_camera_intrinsics(handle, fx, fy, cx, cy, buf.baseAddress, UInt32(buf.count)))
        }
    }

    /// The latest caption an audio.infer node decoded, by the node's id, or nil
    /// when that node has no caption binding or nothing decoded yet. On-device ASR
    /// the app can draw as a live subtitle. A length probe sizes the buffer.
    public func captionText(_ nodeId: String) -> String? {
        let id = Array(nodeId.utf8)
        var needed: Int = 0
        guard goss_session_caption_text(handle, id, id.count, nil, 0, &needed) == GOSS_OK, needed > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: needed)
        var written: Int = 0
        guard goss_session_caption_text(handle, id, id.count, &out, out.count, &written) == GOSS_OK else { return nil }
        return String(decoding: out[0..<written], as: UTF8.self)
    }

    /// Segments a host-provided still image through the running segmenter:
    /// rgba is width by height RGBA8 pixels, row major. The mask reaches the
    /// active lens the way a camera frame's would. Throws again with no
    /// segmenter enabled.
    public func submitSegmentationImage(_ rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try rgba.withUnsafeBufferPointer { buf in
            try checked(goss_session_submit_segmentation_image(handle, buf.baseAddress, width, height))
        }
    }

    /// Feeds a segmentation mask the host tracking module computed as the
    /// subject texture the blend and mask channels sample: mask_side squared
    /// floats, row major. An empty array clears it. The web analysis-producer
    /// path; throws .unsupported off the web, where the in-engine worker runs.
    public func setSegmentationMask(_ mask: [Float]) throws {
        if mask.isEmpty {
            try checked(goss_session_set_segmentation_mask(handle, nil, 0))
            return
        }
        try mask.withUnsafeBufferPointer { buf in
            try checked(goss_session_set_segmentation_mask(handle, buf.baseAddress, UInt32(mask.count)))
        }
    }

    /// The class channels the active lens samples, as a bitmask over the mask
    /// channels (bit 0 person, bit 1 background, and so on). The host uploads
    /// exactly these class masks each frame with setSegmentationClassMask;
    /// zero means only the subject mask is wanted.
    public func segmentationChannels() -> UInt32 {
        goss_session_segmentation_channels(handle)
    }

    /// Uploads one class channel's mask (mask_side squared floats) as the
    /// texture that channel's passes sample. channel indexes the mask
    /// channels; channel 0 (person) rides setSegmentationMask, which clears
    /// the classes, so upload the classes after it. An empty array clears one.
    public func setSegmentationClassMask(channel: UInt32, mask: [Float]) throws {
        if mask.isEmpty {
            try checked(goss_session_set_segmentation_class_mask(handle, channel, nil, 0))
            return
        }
        try mask.withUnsafeBufferPointer { buf in
            try checked(goss_session_set_segmentation_class_mask(handle, channel, buf.baseAddress, UInt32(mask.count)))
        }
    }

    /// Samples a reference photo's makeup color per face part, so a tint.pass
    /// with a reference source paints the live face in that color. rgba is
    /// width by height RGBA8; landmarks is the reference face's 478 x, y, z
    /// points. An empty landmarks array clears the reference.
    public func setMakeupReference(_ rgba: [UInt8], width: UInt32, height: UInt32, landmarks: [Float]) throws {
        if landmarks.isEmpty {
            try checked(goss_session_set_makeup_reference(handle, nil, 0, 0, nil, 0))
            return
        }
        try rgba.withUnsafeBufferPointer { rbuf in
            try landmarks.withUnsafeBufferPointer { lbuf in
                try checked(goss_session_set_makeup_reference(handle, rbuf.baseAddress, width, height, lbuf.baseAddress, UInt32(landmarks.count / 3)))
            }
        }
    }

    /// The number of bodies the last submitBodies kept, zero to GOSS_BODY_MAX.
    public func bodyCount() throws -> Int {
        var count: UInt32 = 0
        try checked(goss_session_body_count(handle, &count))
        return Int(count)
    }

    /// Fills result with the index-th submitted body. Throws .invalidArgument
    /// once index reaches bodyCount, so a caller loops zero to bodyCount to
    /// visit every body.
    public func bodyResult(at index: Int, into result: GossPoseResult) throws {
        try checked(goss_session_body_result_at(handle, UInt32(index), &result.raw))
        result.parse()
    }

    /// Fills result with the newest hand tracking output. Throws .again
    /// until the hand worker has published its first result.
    public func handResult(_ result: GossHandResult) throws {
        try checked(goss_session_hand_result(handle, &result.raw))
        result.parse()
    }

    /// Fills result with the newest pose tracking output. Throws .again
    /// until the pose worker has published its first result.
    public func poseResult(_ result: GossPoseResult) throws {
        try checked(goss_session_pose_result(handle, &result.raw))
        result.parse()
    }

    /// Fills matrix with the column-major head transform - canonical
    /// metric space into frame pixels. Throws .again until a face is
    /// tracked; matrix must hold at least sixteen floats.
    public func facePose(_ matrix: inout [Float]) throws {
        precondition(matrix.count >= 16)
        try matrix.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_face_pose(handle, buffer.baseAddress))
        }
    }

    /// The tracked point (x, y in frame pixels, z in the same scale) of a
    /// named face region, so a lens pins content to the forehead, a cheek, or
    /// the chin. Throws .again until a face is tracked.
    public func faceRegion(_ region: GossFaceRegion) throws -> (x: Float, y: Float, z: Float) {
        var xyz: [Float] = [0, 0, 0]
        try xyz.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_face_region(handle, region.rawValue, buffer.baseAddress))
        }
        return (xyz[0], xyz[1], xyz[2])
    }

    /// The tracked point (x, y in frame pixels, z in the same scale) of a named
    /// body skeleton joint, so a lens pins content to a shoulder, a wrist, or a
    /// knee. Throws .again until a body is tracked.
    public func bodyJoint(_ joint: GossBodyJoint) throws -> (x: Float, y: Float, z: Float) {
        var xyz: [Float] = [0, 0, 0]
        try xyz.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_body_joint(handle, joint.rawValue, buffer.baseAddress))
        }
        return (xyz[0], xyz[1], xyz[2])
    }

    /// The tracked point (x, y in frame pixels, z in the same scale) of a named
    /// joint on the handIndex-th tracked hand, so a lens pins content to a
    /// fingertip or the wrist. Throws .again until that hand is tracked.
    public func handJoint(_ joint: GossHandJoint, hand handIndex: Int = 0) throws -> (x: Float, y: Float, z: Float) {
        var xyz: [Float] = [0, 0, 0]
        try xyz.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_hand_joint(handle, UInt32(handIndex), joint.rawValue, buffer.baseAddress))
        }
        return (xyz[0], xyz[1], xyz[2])
    }

    /// The degradation level currently in effect.
    public func degradeLevel() -> GossDegradeLevel {
        GossDegradeLevel(rawValue: goss_session_degrade_level(handle).rawValue) ?? .passthrough
    }
}
