/// An audio session change the engine reacts to. Parsed from `AVAudioSession` notifications on iOS
/// by `AudioSessionController`; platform-independent so the handling is testable on macOS.
public enum AudioSessionEvent: Sendable, Hashable {
    /// The system deactivated the audio session (`didBecomeInactiveNotification` with a system source).
    case interruptionBegan
    /// The system sent a resumption recommendation; `shouldResume` is `.shouldResume`.
    case interruptionEnded(shouldResume: Bool)
    /// The previous output (headphones, Bluetooth) went away.
    case oldDeviceUnavailable
}

/// Pauses and resumes an engine for audio session interruptions and unplugged outputs.
///
/// - Interruption began: pause, and remember whether playback was requested.
/// - Resumption recommended (`shouldResume`): resume only if playback was requested when it began.
///   ``AudioEngineProtocol/play()`` re-applies the default rate.
/// - Old device unavailable: pause and forget any pending resume.
@MainActor
public final class AudioInterruptionHandler {
    public weak var engine: (any AudioEngineProtocol)?
    private var resumeAfterInterruption = false

    public init(engine: (any AudioEngineProtocol)? = nil) {
        self.engine = engine
    }

    public func handle(_ event: AudioSessionEvent) {
        guard let engine else { return }
        switch event {
        case .interruptionBegan:
            resumeAfterInterruption = engine.isPlaybackRequested
            if engine.isPlaybackRequested { engine.pause() }
        case .interruptionEnded(let shouldResume):
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if resume && !engine.isPlaybackRequested { engine.play() }
        case .oldDeviceUnavailable:
            resumeAfterInterruption = false
            if engine.isPlaybackRequested { engine.pause() }
        }
    }
}
