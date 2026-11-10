import AVFoundation
import os

#if os(iOS)
    import AudioToolbox
#endif

private let logger = Logger(subsystem: "org.davidjensenius.Audiobookshelf", category: "SleepTimer")

/// The sounds and vibrations of a ``SleepTimer``.
@MainActor
public protocol SleepTimerFeedback: AnyObject {
    /// The almost-done chime, ``SleepTimer/chimeLeadTime`` seconds before the timer pauses playback.
    func playChime()
    /// Confirms that ``SleepTimer/reset()`` restarted the timer.
    func playResetFeedback()
}

/// Plays a synthesized bell for the chime and vibrates (iOS only) for a reset. On macOS the chime plays through
/// the default system output, which may not be the device playing the book.
@MainActor
public final class SystemSleepTimerFeedback: SleepTimerFeedback {
    /// The Android `SLEEP_TIMER_CHIME_SOUND_VOLUME`.
    static let chimeVolume: Float = 0.7
    static let chimeDuration: Double = 1.5
    static let sampleRate: Double = 44_100
    private static let fundamental: Double = 880
    /// Frequency ratio, amplitude and exponential decay rate of each partial.
    private static let partials: [(ratio: Double, amplitude: Double, decay: Double)] = [
        (1, 0.6, 3), (2.76, 0.25, 5), (5.4, 0.1, 8),
    ]

    /// Synthesized once.
    private static let chime = makeChime()

    /// One engine and node for every chime; the engine stops between chimes. Rebuilt after a configuration
    /// change (a route or format change), which stops the engine.
    private var output: (engine: AVAudioEngine, node: AVAudioPlayerNode, observer: any NSObjectProtocol)?
    /// Counts the outputs built, so a late notification from a dropped engine can't drop its replacement.
    private(set) var outputGeneration = 0
    private var chimeGeneration = 0

    var hasOutput: Bool { output != nil }

    public init() {}

    isolated deinit {
        discardOutput()
    }

    public func playChime() {
        guard let buffer = Self.chime, let output = chimeOutput(format: buffer.format) else { return }
        do {
            try output.engine.start()
        } catch {
            logger.error("Sleep timer chime failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        chimeGeneration += 1
        let generation = chimeGeneration
        output.node.stop()
        output.node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.chimeDidFinish(generation) }
        }
        do {
            try output.node.playAudio()
        } catch {
            logger.error("Sleep timer chime failed: \(error.localizedDescription, privacy: .public)")
            chimeDidFinish(generation)
        }
    }

    public func playResetFeedback() {
        #if os(iOS)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        #endif
    }

    func chimeOutput(format: AVAudioFormat) -> (engine: AVAudioEngine, node: AVAudioPlayerNode)? {
        if let output { return (output.engine, output.node) }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        node.volume = Self.chimeVolume
        do {
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
        } catch {
            logger.error("Sleep timer chime failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        outputGeneration += 1
        let generation = outputGeneration
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Safe: the observer runs on `OperationQueue.main`, which executes on the main thread.
            MainActor.assumeIsolated { _ = self?.configurationDidChange(generation: generation) }
        }
        output = (engine, node, observer)
        return (engine, node)
    }

    /// Drops the output in a later main-actor task, not inside the engine's own notification: releasing an
    /// `AVAudioEngine` there can deadlock, and running the observer on the main queue doesn't prevent that. The
    /// task drops only the output that posted, because a late or repeated notification mustn't drop a rebuilt one.
    @discardableResult
    func configurationDidChange(generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self, generation == outputGeneration else { return }
            discardOutput()
        }
    }

    private func discardOutput() {
        if let observer = output?.observer { NotificationCenter.default.removeObserver(observer) }
        output = nil
    }

    private func chimeDidFinish(_ generation: Int) {
        guard generation == chimeGeneration else { return }
        output?.engine.stop()
    }

    /// A mono bell: decaying inharmonic partials over an 880 Hz fundamental with a 5 ms attack. Peaks below 1.
    static func makeChime() -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(chimeDuration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
            let samples = buffer.floatChannelData?[0]
        else { return nil }
        let attackFrames = 0.005 * sampleRate
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let attack = min(Double(frame) / attackFrames, 1)
            let value = partials.reduce(0) { sum, partial in
                sum + partial.amplitude * exp(-partial.decay * time)
                    * sin(2 * .pi * fundamental * partial.ratio * time)
            }
            samples[frame] = Float(attack * value)
        }
        buffer.frameLength = frameCount
        return buffer
    }
}
