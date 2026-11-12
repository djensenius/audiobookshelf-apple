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

/// A play intent held outside the engine, which pausing the engine doesn't cancel: recovery's
/// restart, a resume awaiting its seek, a starting item. ``PlaybackCoordinator`` holds them.
@MainActor
public protocol HeldPlayIntent: AnyObject {
    /// Drops the held intent, as a pause would; returns whether there was one.
    func cancelHeldPlayIntent() -> Bool
    /// Restores it after an interruption ends with a resumption recommended.
    func resumeHeldPlayIntent()
}

extension PlaybackCoordinator: HeldPlayIntent {}

/// Pauses and resumes an engine for audio session interruptions and unplugged outputs.
///
/// - Interruption began: pause, and remember that playback should resume if it was requested
///   (a second `began` keeps an earlier resume).
/// - Resumption recommended (`shouldResume`): resume if the flag is still set.
///   ``AudioEngineProtocol/play()`` re-applies the default rate.
/// - A play held outside the engine (``heldPlayIntent``, such as a recovering item's) is cancelled
///   at the start too, and restored through it instead of the engine.
/// - The flag is cleared by the session becoming active again, by an unplugged output, and by any
///   user play or pause (``userDidChangePlayback()``), so a late recommendation never restarts
///   playback the user paused.
@MainActor
public final class AudioInterruptionHandler {
    public weak var engine: (any AudioEngineProtocol)?
    /// Set to the coordinator driving ``engine``.
    public weak var heldPlayIntent: (any HeldPlayIntent)?
    private(set) var resumeAfterInterruption = false
    /// The resume goes through ``heldPlayIntent``.
    private var resumeHeldIntent = false

    public init(engine: (any AudioEngineProtocol)? = nil) {
        self.engine = engine
    }

    /// Call when the user plays or pauses (UI, remote commands, CarPlay).
    public func userDidChangePlayback() {
        resumeAfterInterruption = false
        resumeHeldIntent = false
    }

    public func handle(_ event: AudioSessionEvent) {
        guard let engine else { return }
        switch event {
        case .interruptionBegan:
            if heldPlayIntent?.cancelHeldPlayIntent() == true {
                resumeAfterInterruption = true
                resumeHeldIntent = true
            }
            resumeAfterInterruption = resumeAfterInterruption || engine.isPlaybackRequested
            if engine.isPlaybackRequested { engine.pause() }
        case .interruptionEnded(let shouldResume):
            let resume = resumeAfterInterruption && shouldResume
            let held = resumeHeldIntent
            userDidChangePlayback()
            guard resume else { return }
            if held, let heldPlayIntent {
                heldPlayIntent.resumeHeldPlayIntent()
            } else if !engine.isPlaybackRequested {
                engine.play()
            }
        case .sessionActivated:
            // Only the app activates its session (the engine before playing), so playback has been
            // restarted by someone and a pending resume is stale.
            userDidChangePlayback()
        case .oldDeviceUnavailable:
            userDidChangePlayback()
            // Even when paused: recovery may be about to restart playback.
            engine.pauseForOutputLoss()
        }
    }
}
