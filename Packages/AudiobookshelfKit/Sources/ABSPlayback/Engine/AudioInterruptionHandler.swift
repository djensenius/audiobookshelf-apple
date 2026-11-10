/// An audio session change the engine reacts to. Parsed from `AVAudioSession` notifications on iOS
/// by `AudioSessionController`; platform-independent so the handling is testable on macOS.
public enum AudioSessionEvent: Sendable, Hashable {
    /// The system deactivated the audio session (`didBecomeInactiveNotification` with a system source).
    case interruptionBegan
    /// The system sent a resumption recommendation; `shouldResume` is `.shouldResume`.
    case interruptionEnded(shouldResume: Bool)
    /// The audio session became active again (`didBecomeActiveNotification`).
    case sessionActivated
    /// The previous output went away. This covers wired headphones, Bluetooth, CarPlay and AirPlay,
    /// which is broader than the legacy app (wired headphones only), matching Apple's guidance.
    case oldDeviceUnavailable
}

/// Pauses and resumes an engine for audio session interruptions and unplugged outputs.
///
/// - Interruption began: pause, and remember that playback should resume if it was requested
///   (a second `began` keeps an earlier resume).
/// - Resumption recommended (`shouldResume`): resume if the flag is still set.
///   ``AudioEngineProtocol/play()`` re-applies the default rate.
/// - The flag is cleared by the session becoming active again, by an unplugged output, and by any
///   user play or pause (``userDidChangePlayback()``), so a late recommendation never restarts
///   playback the user paused.
@MainActor
public final class AudioInterruptionHandler {
    public weak var engine: (any AudioEngineProtocol)?
    private(set) var resumeAfterInterruption = false

    public init(engine: (any AudioEngineProtocol)? = nil) {
        self.engine = engine
    }

    /// Call when the user plays or pauses (UI, remote commands, CarPlay).
    public func userDidChangePlayback() {
        resumeAfterInterruption = false
    }

    public func handle(_ event: AudioSessionEvent) {
        guard let engine else { return }
        switch event {
        case .interruptionBegan:
            resumeAfterInterruption = resumeAfterInterruption || engine.isPlaybackRequested
            if engine.isPlaybackRequested { engine.pause() }
        case .interruptionEnded(let shouldResume):
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            if resume && !engine.isPlaybackRequested { engine.play() }
        case .sessionActivated:
            // Only the app activates its session (the engine before playing), so playback has been
            // restarted by someone and a pending resume is stale.
            resumeAfterInterruption = false
        case .oldDeviceUnavailable:
            resumeAfterInterruption = false
            if engine.isPlaybackRequested { engine.pause() }
        }
    }
}
