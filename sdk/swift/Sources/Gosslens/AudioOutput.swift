import AVFoundation

/// Routes the lens mixer to the device speaker. The engine's pull is
/// graph-thread only, so `pump()` runs in the frame loop and fills a
/// ring the audio thread's source node drains; an underrun plays
/// silence rather than blocking either side.
public final class GossAudioOutput {
    /// The lens mixer's fixed output format.
    public static let sampleRate: Double = 48_000
    private static let ringFrames = 16_384

    private let session: GossSession
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var ring = [Int16](repeating: 0, count: ringFrames)
    private var readIndex = 0
    private var writeIndex = 0
    private let lock = NSLock()
    private var pull = [Int16](repeating: 0, count: 4096)

    public init(session: GossSession) {
        self.session = session
    }

    /// Starts the platform audio engine with a mono source at the
    /// mixer rate; safe to call once after the session exists.
    public func start() throws {
        guard source == nil else { return }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                   channels: 1, interleaved: true)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let raw = buffers[0].mData else { return noErr }
            let out = raw.bindMemory(to: Int16.self, capacity: Int(frameCount))
            self.lock.lock()
            for i in 0..<Int(frameCount) {
                if self.readIndex != self.writeIndex {
                    out[i] = self.ring[self.readIndex]
                    self.readIndex = (self.readIndex + 1) % Self.ringFrames
                } else {
                    out[i] = 0
                }
            }
            self.lock.unlock()
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw error
        }
        source = node
    }

    /// Pulls the next mixer block into the ring. Call once per frame
    /// from the same thread that ticks the lens.
    public func pump(frames: UInt32 = 800) throws {
        let count = min(Int(frames), pull.count)
        try session.pullAudio(into: &pull, frames: UInt32(count))
        lock.lock()
        for i in 0..<count {
            let next = (writeIndex + 1) % Self.ringFrames
            if next == readIndex { break }
            ring[writeIndex] = pull[i]
            writeIndex = next
        }
        lock.unlock()
    }

    /// Stops the platform engine and detaches the source.
    public func stop() {
        if let node = source {
            engine.detach(node)
            source = nil
        }
        engine.stop()
    }

    deinit {
        stop()
    }
}
