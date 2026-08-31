import CGosslens

/// Frame-path pool bounds; zero means the built-in default.
public struct GossEngineConfig {
    public var texturePoolCapacity: UInt32
    public var stagingPoolCapacity: UInt32

    public init(texturePoolCapacity: UInt32 = 0, stagingPoolCapacity: UInt32 = 0) {
        self.texturePoolCapacity = texturePoolCapacity
        self.stagingPoolCapacity = stagingPoolCapacity
    }
}

/// Render-surface lifecycle: create/destroy/init/resize/render. Confined
/// to the thread that creates it, the graph thread - unchecked because
/// that confinement is the ABI's own contract, not something the
/// compiler can see through an opaque handle.
public final class GossEngine: @unchecked Sendable {
    let handle: OpaquePointer
    private var destroyed = false
    /// Reused scratch for the row-padded live-frame readback fallback, grown
    /// to the frame then reused, so a padded publish never allocates per frame.
    var liveRowScratch: [UInt8] = []

    public static func create(config: GossEngineConfig = GossEngineConfig()) throws -> GossEngine {
        var raw = goss_engine_config(
            texture_pool_capacity: config.texturePoolCapacity,
            staging_pool_capacity: config.stagingPoolCapacity
        )
        var handle: OpaquePointer?
        try checked(goss_engine_create(&raw, &handle))
        guard let handle else { throw GossStatus.outOfMemory }
        return GossEngine(handle: handle)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if !destroyed { goss_engine_destroy(handle) }
    }

    /// Safe to call more than once; only the first call reaches the ABI -
    /// deinit falls back to this same destroy for callers who never call
    /// it explicitly, and must not double-free a handle this already did.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        goss_engine_destroy(handle)
    }

    /// Brings up the render backend on the given surface.
    public func initRenderer(surface: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) throws {
        var desc = goss_renderer_desc(native_window_handle: surface, width: width, height: height)
        try checked(goss_engine_init_renderer(handle, &desc))
    }

    public func resize(width: UInt32, height: UInt32) {
        goss_engine_resize(handle, width, height)
    }

    /// Draws session's most recent frame to the surface and presents. A
    /// nil session presents the clear color.
    public func renderFrame(session: GossSession?) throws {
        try checked(goss_engine_render_frame(handle, session?.handle))
    }

    /// Compiles a text prompt into a GLF lens manifest on device. The result is
    /// ordinary GLF the caller can inspect or pass to activateLens, and needs no
    /// assets. A length probe sizes the buffer, then a fill call writes it.
    public func compilePrompt(_ prompt: String) throws -> String {
        let bytes = Array(prompt.utf8)
        var needed: Int = 0
        try checked(goss_compile_prompt(handle, bytes, bytes.count, nil, 0, &needed))
        var out = [UInt8](repeating: 0, count: needed)
        var written: Int = 0
        try checked(goss_compile_prompt(handle, bytes, bytes.count, &out, out.count, &written))
        return String(decoding: out[0..<written], as: UTF8.self)
    }

    /// Composes an on-device generative-music track from a text prompt and
    /// returns it as a mono 16-bit WAV. A non-zero seed varies the take; bars 0
    /// uses the default length. Deterministic, no model and no network.
    public func generateSong(_ prompt: String, sampleRate: UInt32 = 48000, seed: UInt32 = 0, bars: UInt32 = 0) throws -> [UInt8] {
        let bytes = Array(prompt.utf8)
        var needed: Int = 0
        try checked(goss_engine_generate_song(handle, bytes, bytes.count, sampleRate, seed, bars, nil, 0, &needed))
        var out = [UInt8](repeating: 0, count: needed)
        var written: Int = 0
        try checked(goss_engine_generate_song(handle, bytes, bytes.count, sampleRate, seed, bars, &out, out.count, &written))
        return Array(out[0..<written])
    }

    /// Scans a width*height 8-bit luminance frame for an EAN-13 / UPC-A barcode,
    /// returning its 13 digits or nil when no checksum-valid symbol is found.
    /// Purely algorithmic and deterministic, no model.
    public func scanBarcode(luminance: [UInt8], width: UInt32, height: UInt32) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 13)
        let ok = goss_engine_scan_barcode(handle, luminance, width, height, &out) == GOSS_OK
        return ok ? out : nil
    }

    /// Scans a width*height 8-bit luminance frame for a QR code and returns its
    /// decoded payload bytes, or nil when no QR decodes. Reed-Solomon error
    /// correction, algorithmic and deterministic, no model.
    public func scanQR(luminance: [UInt8], width: UInt32, height: UInt32) -> [UInt8]? {
        var needed: Int = 0
        if goss_engine_scan_qr(handle, luminance, width, height, nil, 0, &needed) != GOSS_OK { return nil }
        var out = [UInt8](repeating: 0, count: needed)
        var written: Int = 0
        if goss_engine_scan_qr(handle, luminance, width, height, &out, out.count, &written) != GOSS_OK { return nil }
        return Array(out[0..<written])
    }

    /// Generates a QR code for a payload and renders it into a square 8-bit
    /// luminance image (0 dark, 255 light), returning the pixels and the side
    /// length. Algorithmic and deterministic, no model.
    public func generateQR(payload: [UInt8], moduleScale: UInt32 = 6, quietModules: UInt32 = 4) -> (image: [UInt8], dim: UInt32)? {
        var dim: UInt32 = 0
        if goss_engine_generate_qr(handle, payload, payload.count, moduleScale, quietModules, nil, 0, &dim) != GOSS_OK { return nil }
        var out = [UInt8](repeating: 0, count: Int(dim) * Int(dim))
        if goss_engine_generate_qr(handle, payload, payload.count, moduleScale, quietModules, &out, out.count, &dim) != GOSS_OK { return nil }
        return (out, dim)
    }

    /// Fingerprints a reference recording and registers it under `trackID` in the
    /// engine's on-device music catalog. Samples are interleaved f32.
    public func addMusicReference(trackID: UInt32, samples: [Float], frameCount: UInt32, sampleRate: UInt32, channels: UInt32) throws {
        try checked(goss_engine_music_add_reference(handle, trackID, samples, frameCount, sampleRate, channels))
    }

    /// Empties the engine's music catalog.
    public func clearMusicReferences() {
        goss_engine_music_clear_references(handle)
    }

    /// Fingerprints a captured snippet and matches it against the catalog,
    /// returning the best track and its vote count, or nil below `minVotes`.
    public func identifyMusic(samples: [Float], frameCount: UInt32, sampleRate: UInt32, channels: UInt32, minVotes: UInt32 = 5) throws -> MusicMatch? {
        var trackID: UInt32 = 0
        var votes: UInt32 = 0
        try checked(goss_engine_music_identify(handle, samples, frameCount, sampleRate, channels, minVotes, &trackID, &votes))
        return votes == 0 ? nil : MusicMatch(trackID: trackID, votes: votes)
    }
}

/// The best track a music snippet matched: its id and how many landmarks agreed.
public struct MusicMatch {
    public let trackID: UInt32
    public let votes: UInt32
}
