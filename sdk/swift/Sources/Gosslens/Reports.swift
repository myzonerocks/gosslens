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
