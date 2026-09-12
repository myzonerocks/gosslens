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
