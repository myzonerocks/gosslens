import CGosslens

/// What the engine is holding right now. Read it on a timer or when a frame
/// looks wrong: an exhausted count that climbs means a pool is too small, and
/// vendor-heap calls above the two bgfx makes per frame mean something started
/// allocating on the frame path.
public struct GossEngineReport: Sendable {
    public var rendererBackend: UInt32
    public var zeroCopyImport: Bool
    public var texturePoolCapacity: UInt32
    public var texturePoolLive: UInt32
    public var texturePoolPeak: UInt32
    public var texturePoolExhausted: UInt32
    public var stagingPoolCapacity: UInt32
    public var stagingPoolLive: UInt32
    public var stagingPoolPeak: UInt32
    public var stagingPoolExhausted: UInt32
    public var texturePoolBins: UInt32
    public var texturePoolBinsRefused: UInt32
    public var stagingPoolBins: UInt32
    public var bgfxLiveBytes: UInt64
    public var bgfxAllocCallsLastFrame: UInt64
    public var bgfxBytesLastFrame: UInt64

    init(_ raw: goss_engine_report) {
        rendererBackend = raw.renderer_backend
        zeroCopyImport = raw.zero_copy_import != 0
        texturePoolCapacity = raw.texture_pool_capacity
        texturePoolLive = raw.texture_pool_live
        texturePoolPeak = raw.texture_pool_peak
        texturePoolExhausted = raw.texture_pool_exhausted
        stagingPoolCapacity = raw.staging_pool_capacity
        stagingPoolLive = raw.staging_pool_live
        stagingPoolPeak = raw.staging_pool_peak
        stagingPoolExhausted = raw.staging_pool_exhausted
        texturePoolBins = raw.texture_pool_bins
        texturePoolBinsRefused = raw.texture_pool_bins_refused
        stagingPoolBins = raw.staging_pool_bins
        bgfxLiveBytes = raw.bgfx_live_bytes
        bgfxAllocCallsLastFrame = raw.bgfx_alloc_calls_last_frame
        bgfxBytesLastFrame = raw.bgfx_bytes_last_frame
    }
}

/// What one session has done. degradeTransitions climbing steadily is the
/// ladder flapping rather than settling, and nodeReportsLost above zero means
/// the report ring overflowed and some node failures were never seen.
public struct GossSessionReport: Sendable {
    public var framesSubmitted: UInt64
    public var framesRendered: UInt64
    public var degradeLevel: GossDegradeLevel
    public var degradeTransitions: UInt32
    public var faceAnalysis: UInt64
    public var handAnalysis: UInt64
    public var poseAnalysis: UInt64
    public var segmentationAnalysis: UInt64
    public var mlAnalysis: UInt64
    public var nodesDegraded: UInt32
    public var nodeReportsLost: UInt32
    public var scriptFaults: UInt32

    init(_ raw: goss_session_report) {
        framesSubmitted = raw.frames_submitted
        framesRendered = raw.frames_rendered
        degradeLevel = GossDegradeLevel(rawValue: raw.degrade_level) ?? .passthrough
        degradeTransitions = raw.degrade_transitions
        faceAnalysis = raw.face_analysis
        handAnalysis = raw.hand_analysis
        poseAnalysis = raw.pose_analysis
        segmentationAnalysis = raw.segmentation_analysis
        mlAnalysis = raw.ml_analysis
        nodesDegraded = raw.nodes_degraded
        nodeReportsLost = raw.node_reports_lost
        scriptFaults = raw.script_faults
    }
}

extension GossEngine {
    public func engineReport() throws -> GossEngineReport {
        var raw = goss_engine_report()
        try checked(goss_engine_read_report(handle, &raw))
        return GossEngineReport(raw)
    }
}

extension GossSession {
    /// The engine this session renders through, for the engine-wide counters.
    public func engineReport() throws -> GossEngineReport {
        try engine.engineReport()
    }

    public func sessionReport() throws -> GossSessionReport {
        var raw = goss_session_report()
        try checked(goss_session_read_report(handle, &raw))
        return GossSessionReport(raw)
    }
}

/// What one recording has done. driftUs is measured, not a tolerance someone
/// chose: the largest gap between consecutive frames that was not a break the
/// host declared.
public struct GossRecordingReport: Sendable {
    public var durationUs: Int64
    public var clips: UInt32
    public var interruptions: UInt32
    public var driftUs: Int64
    public var frames: UInt64
    public var dropped: UInt64
    public var paused: Bool

    init(_ raw: goss_recording_report) {
        durationUs = raw.duration_us
        clips = raw.clips
        interruptions = raw.interruptions
        driftUs = raw.drift_us
        frames = raw.frames
        dropped = raw.dropped
        paused = raw.paused != 0
    }
}

/// What interrupted a recording, as the host saw it.
public enum GossInterruption: UInt32, Sendable {
    case pause = 0, cameraLost = 1, audioRoute = 2, backgrounded = 3, thermal = 4
}

extension GossSession {
    /// A break the engine cannot detect: the camera went away, the audio route
    /// changed, the app was backgrounded, thermal pressure stopped the encoder.
    public func reportInterruption(_ kind: GossInterruption) throws {
        try checked(goss_session_report_interruption(handle, goss_interruption(rawValue: kind.rawValue)))
    }
}

/// What an opened clip is and where it is, so a caller scrubbing a timeline reads
/// it rather than guessing from a frame count and an authored frame rate.
public struct GossClipInfo: Sendable {
    public var width: UInt32
    public var height: UInt32
    public var durationUs: Int64
    public var positionUs: Int64
    public var ended: Bool

    init(_ raw: goss_clip_info) {
        width = raw.width
        height = raw.height
        durationUs = raw.duration_us
        positionUs = raw.position_us
        ended = raw.ended != 0
    }
}

/// What this build's media backend declares it encodes, as bit sets over the codec
/// and container enums, so a host asks rather than assuming from the platform.
public struct GossMediaCapabilities: Sendable {
    public var videoCodecs: UInt32
    public var audioCodecs: UInt32
    public var containers: UInt32
    public var maxWidth: UInt32
    public var maxHeight: UInt32
    public var maxBitDepth: UInt32
    public var hdr: Bool
    public var zeroCopy: Bool

    init(_ raw: goss_media_capabilities) {
        videoCodecs = raw.video_codecs
        audioCodecs = raw.audio_codecs
        containers = raw.containers
        maxWidth = raw.max_width
        maxHeight = raw.max_height
        maxBitDepth = raw.max_bit_depth
        hdr = raw.hdr != 0
        zeroCopy = raw.zero_copy != 0
    }
}

extension GossEngine {
    public func mediaCapabilities() throws -> GossMediaCapabilities {
        var raw = goss_media_capabilities()
        try checked(goss_engine_media_capabilities(handle, &raw))
        return GossMediaCapabilities(raw)
    }
}

/// One thing that happened. What `a` and `b` mean is per kind.
public struct GossEvent: Sendable {
    public var kind: GossEventKind
    public var sequence: UInt64
    public var timestampUs: Int64
    public var a: UInt32
    public var b: UInt32
    public var value: Float

    init(_ raw: goss_event) {
        kind = GossEventKind(rawValue: raw.kind) ?? .unknown
        sequence = raw.sequence
        timestampUs = raw.timestamp_us
        a = raw.a
        b = raw.b
        value = raw.value
    }
}

/// The event kinds, mirroring goss_event_kind. An unknown number from a newer
/// engine reads as `.unknown` rather than failing the drain.
public enum GossEventKind: UInt32, Sendable {
    case unknown = 0
    case faceAppeared = 1, faceLost = 2, faceCountChanged = 3
    case handAppeared = 4, handLost = 5, gestureRecognised = 6
    case bodyAppeared = 7, bodyLost = 8, actionRecognised = 9
    case trackingStateChanged = 10
    case planeAdded = 11, planeUpdated = 12, anchorAdded = 13, anchorLost = 14
    case worldMeshUpdated = 15
    case detectionAppeared = 16, detectionLost = 17, labelChanged = 18
    case textAppeared = 19, textChanged = 20
    case segmentationClassAppeared = 21
    case audioBeat = 22, voiceActivityStarted = 23, voiceActivityEnded = 24
    case lensActivated = 25, lensNodeDegraded = 26, lensNodeFailed = 27
    case parameterChanged = 28, triggerFired = 29
    case degradeLevelChanged = 30, poolExhausted = 31
    case recordingStarted = 32, recordingPaused = 33, recordingResumed = 34, recordingStopped = 35
    case interruption = 36, frameDropped = 37, budgetExceeded = 38, thermalChanged = 39
}

extension GossSession {
    /// The session's events as an `AsyncSequence`, which is how a Swift caller
    /// wants them: `for await event in session.events()`. Polls on an interval
    /// rather than blocking a thread, because the ring is drained by the caller
    /// and there is nothing to await on the engine side.
    ///
    /// `dropped` is surfaced as an event of its own rather than swallowed: a
    /// consumer that missed something must be able to know it did.
    public func events(pollInterval: Duration = .milliseconds(16), batch: Int = 64) -> AsyncStream<GossEvent> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let drained = try? self.pollEvents(capacity: batch) {
                        for event in drained.events { continuation.yield(event) }
                        if drained.dropped > 0 {
                            // A synthetic event carrying the count, so a drop is
                            // visible in the same stream rather than in a return
                            // value a for-await loop never sees.
                            var notice = GossEvent(goss_event())
                            notice.kind = .unknown
                            notice.a = UInt32(truncatingIfNeeded: drained.dropped)
                            continuation.yield(notice)
                        }
                    }
                    try? await Task.sleep(for: pollInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// What the brain sees and what it costs. The budget is held before any trigger
/// is consulted, because a budget a trigger can talk past is not a budget.
public struct GossEgressConfig: Sendable {
    public var targetLongEdge: UInt32 = 0
    public var format: UInt32 = 0
    public var quality: UInt32 = 80
    public var maxFps: UInt32 = 0
    public var maxBytesPerSecond: UInt64 = 0
    public var source: UInt32 = 0
    public var trigger: UInt32 = 0b1010
    public var changeThreshold: Float = 0.02
    public var keyframeIntervalUs: Int64 = 5_000_000

    public init() {}

    var raw: goss_egress_config {
        goss_egress_config(
            target_long_edge: targetLongEdge, format: format, quality: quality,
            max_fps: maxFps, max_bytes_per_second: maxBytesPerSecond, source: source,
            trigger: trigger, change_threshold: changeThreshold,
            keyframe_interval_us: keyframeIntervalUs
        )
    }
}

/// Why a frame was or was not sent, so a gateway can explain itself.
public struct GossEgressDecision: Sendable {
    public var send: Bool
    public var reason: UInt32
    public var changeScore: Float
    public var sinceLastUs: Int64
    public var sentTotal: UInt64
    public var heldTotal: UInt64

    init(_ raw: goss_egress_decision) {
        send = raw.send != 0
        reason = raw.reason
        changeScore = raw.change_score
        sinceLastUs = raw.since_last_us
        sentTotal = raw.sent_total
        heldTotal = raw.held_total
    }
}

/// One thing an agent draws back into the frame. Carries its own lifetime, because
/// the failure mode of an imperative overlay is annotations nobody removed.
public struct GossAnnotation: Sendable {
    public var id: UInt32
    public var kind: UInt32
    public var space: UInt32 = 0
    public var rect: (Float, Float, Float, Float) = (0, 0, 0, 0)
    public var trackId: UInt32 = 0
    public var colour: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
    public var z: Int32 = 0
    public var opacity: Float = 1
    public var lifetimeKind: UInt32 = 0
    public var lifetimeValue: Int64 = 0
    public var onLost: UInt32 = 0
    public var value: Float = 0

    public init(id: UInt32, kind: UInt32) {
        self.id = id
        self.kind = kind
    }

    var raw: goss_annotation {
        goss_annotation(
            id: id, kind: kind, space: space,
            rect: (rect.0, rect.1, rect.2, rect.3),
            track_id: trackId, colour: (colour.0, colour.1, colour.2, colour.3),
            z: z, opacity: opacity, lifetime_kind: lifetimeKind,
            lifetime_value: lifetimeValue, on_lost: onLost, value: value
        )
    }
}

/// The operators a model needs that this build does not implement. An empty
/// list means the model runs; anything in it names exactly what is missing,
/// which beats a bare "unsupported" when choosing a model.
public func gossMlOpSupport(_ model: [UInt8]) -> [String] {
    var capacity = 256
    while capacity <= 1 << 16 {
        var out = [UInt8](repeating: 0, count: capacity)
        var needed = 0
        let status = model.withUnsafeBufferPointer { modelPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                goss_ml_op_support(modelPtr.baseAddress, model.count, outPtr.baseAddress, capacity, &needed)
            }
        }
        if status != GOSS_OK && status != GOSS_AGAIN { return [] }
        if needed <= capacity {
            let text = String(decoding: out[0..<needed], as: UTF8.self)
            return text.split(separator: "\n").map(String.init)
        }
        capacity = needed
    }
    return []
}

/// What the frame says at one place in it. The quadrilateral is in normalized
/// frame space and in reading order, so a coordinate sent back maps to a pixel.
public struct GossReading: Sendable {
    public let text: String
    public let quad: [Float]
    public let confidence: Float
    public let origin: UInt32
    public let script: UInt32
    public let direction: UInt32
    public let trackId: UInt32
    public let line: UInt32
    public let paragraph: UInt32

    init(raw: goss_text_entry, text: String) {
        self.text = text
        self.quad = [
            raw.quad.0, raw.quad.1, raw.quad.2, raw.quad.3,
            raw.quad.4, raw.quad.5, raw.quad.6, raw.quad.7,
        ]
        self.confidence = raw.confidence
        self.origin = raw.origin
        self.script = raw.script
        self.direction = raw.direction
        self.trackId = raw.track_id
        self.line = raw.line
        self.paragraph = raw.paragraph
    }
}

/// What the engine will let this process capture. Scale is the field to carry
/// through: a point sent back without it lands at half its place on a retina
/// display.
public struct GossScreenSurface: Sendable {
    public let id: UInt64
    public let kind: UInt32
    public let title: String
    public let logicalWidth: Float
    public let logicalHeight: Float
    public let originX: Float
    public let originY: Float
    public let scale: Float
}

public extension GossEngine {
    /// Everything capturable. Empty where permission has not been granted, so
    /// prompt rather than treating it as an error.
    func screens() throws -> [GossScreenSurface] {
        var count: UInt32 = 0
        let status = goss_engine_screen_count(handle, &count)
        if status == GOSS_UNSUPPORTED { return [] }
        try checked(status)
        var out: [GossScreenSurface] = []
        out.reserveCapacity(Int(count))
        for index in 0..<count {
            var raw = goss_screen_surface()
            try checked(goss_engine_screen_at(handle, index, &raw))
            var needed = 0
            _ = goss_engine_screen_title(handle, index, nil, 0, &needed)
            var title = ""
            if needed > 0 {
                var bytes = [UInt8](repeating: 0, count: needed)
                let titleStatus = bytes.withUnsafeMutableBufferPointer { buffer in
                    goss_engine_screen_title(handle, index, buffer.baseAddress, needed, &needed)
                }
                if titleStatus == GOSS_OK { title = String(decoding: bytes, as: UTF8.self) }
            }
            out.append(GossScreenSurface(
                id: raw.id, kind: raw.kind, title: title,
                logicalWidth: raw.logical_width, logicalHeight: raw.logical_height,
                originX: raw.origin_x, originY: raw.origin_y, scale: raw.scale
            ))
        }
        return out
    }
}
