import AVFoundation

/// Feeds the device microphone into the session: the web SDK's GossMicInput, brought here so
/// practice, live and capture do not each write their own interleave. The engine resamples
/// whatever rate the device hands over, so this passes the hardware format through.
public final class GossMicInput {
    private let session: GossSession
    private let engineHandle: GossEngine
    private let engine = AVAudioEngine()
    private var interleaved: [Float] = []
    private var running = false

    public init(session: GossSession, engine: GossEngine) {
        self.session = session
        self.engineHandle = engine
    }

    /// Taps the input node and submits every buffer. Requires the app to have arranged microphone
    /// permission and an active, category-appropriate `AVAudioSession`; this deliberately does not
    /// touch either, because the app owns that policy and a call or broadcast may already hold it.
    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw GossStatus.invalidArgument }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            self?.submit(buffer, at: when)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Interleaves the platform's per-channel float buffer and hands it over. Reuses one array so
    /// a tap running every few milliseconds allocates nothing after the first buffer.
    private func submit(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return }
        let needed = frames * count
        if interleaved.count < needed { interleaved = [Float](repeating: 0, count: needed) }
        interleaved.withUnsafeMutableBufferPointer { out in
            for c in 0..<count {
                let src = channels[c]
                for f in 0..<frames { out[f * count + c] = src[f] }
            }
        }
        let seconds = Double(when.sampleTime) / when.sampleRate
        let stamp = Int64(seconds * 1_000_000)
        try? engineHandle.submitAudio(session: session, samples: Array(interleaved[0..<needed]),
                                frameCount: UInt32(frames), sampleRate: UInt32(buffer.format.sampleRate),
                                channels: UInt32(count), timestampUs: stamp)
    }
}
