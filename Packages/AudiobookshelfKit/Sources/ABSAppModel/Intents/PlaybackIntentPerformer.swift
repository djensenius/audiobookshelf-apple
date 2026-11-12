import ABSCore
import ABSPlayback

/// Why a playback intent (Siri, Shortcuts, the Action button) couldn't do what it was asked. The app
/// shows each as a localized dialog.
public enum PlaybackIntentFailure: Error, Equatable, Sendable {
    /// No item is loaded or restored: nothing has played on this account yet, or nobody is signed in.
    case nothingToResume
    /// No item is loaded or restored to pause, jump in, time or speed up.
    case nothingPlaying
    /// The current playback has no sleep timer.
    case sleepTimerUnavailable
    /// End of chapter was asked for with no chapter or track end ahead.
    case noChapterEnd
    /// Playback didn't start: the streaming policy blocked it or asks first, the session failed to
    /// start, or the audio session wouldn't activate. The player shows why when the app is opened.
    case playbackFailed
}

/// The sleep timer command a playback intent needs. ``ABSPlayback/SleepTimer`` conforms; tests pass a fake.
@MainActor
public protocol SleepTimerStarting: AnyObject {
    /// Starts a timer, replacing any running one; `false` if it couldn't start.
    @discardableResult func start(_ mode: SleepTimerMode) -> Bool
}

extension SleepTimer: SleepTimerStarting {}

/// What a sleep timer intent asks for.
public enum PlaybackSleepRequest: Equatable, Sendable {
    /// Pause after this many minutes of playback.
    case minutes(Int)
    /// Pause at the end of the chapter that's playing.
    case endOfChapter
}

/// Maps playback intents to the player, so the `AppIntent` types stay thin and this can be tested with a
/// fake. Commands go to the same ``PlayerPlaybackControlling`` the player screens use (``CurrentPlayback``
/// in the app) and follow the player's mappings: toggle follows the play intent, jumps go through
/// ``PlayerPlaybackControlling/jump(by:)`` with the user's intervals by default, and rates are
/// normalized like the speed stepper's.
@MainActor
public struct PlaybackIntentPerformer {
    let playback: any PlayerPlaybackControlling
    let sleepTimer: (any SleepTimerStarting)?
    let settings: AppSettings

    /// - Parameters:
    ///   - playback: The signed-in account's playback; idle (nothing to control) when signed out.
    ///   - sleepTimer: The current playback's sleep timer, or `nil` when there is none.
    ///   - settings: The jump intervals used when an intent doesn't give one.
    public init(playback: any PlayerPlaybackControlling, sleepTimer: (any SleepTimerStarting)?, settings: AppSettings) {
        self.playback = playback
        self.sleepTimer = sleepTimer
        self.settings = settings
    }

    /// Resumes the current item, or starts the last-played one, which the account's playback restores
    /// (paused and unloaded) when its session starts. Already playing, the player ignores it.
    /// - Throws: ``PlaybackIntentFailure/nothingToResume`` when no item is loaded or restored, and
    ///   ``PlaybackIntentFailure/playbackFailed`` when the player didn't start: its `resume` doesn't
    ///   throw, but a blocked or failed start leaves play no longer requested (a pause that races the
    ///   resume reads the same).
    public func resume() async throws(PlaybackIntentFailure) {
        guard playback.phase != .idle else { throw .nothingToResume }
        await playback.resume(rewindingBy: nil)
        guard playback.isPlaybackRequested else { throw .playbackFailed }
    }

    /// Pauses, including a first play still waiting on its streaming-policy check (the player is
    /// still idle then, with play requested), which the player's pause cancels.
    /// - Throws: ``PlaybackIntentFailure/nothingPlaying`` when nothing is loaded, restored or starting.
    public func pause() throws(PlaybackIntentFailure) {
        guard playback.phase != .idle || playback.isPlaybackRequested else { throw .nothingPlaying }
        playback.pause()
    }

    /// Pauses while play is requested (also while starting or stalled), else resumes, as the player's
    /// play/pause button does.
    /// - Throws: ``PlaybackIntentFailure/nothingToResume`` when no item is loaded or restored.
    public func togglePlayPause() async throws(PlaybackIntentFailure) {
        if playback.isPlaybackRequested {
            try pause()
        } else {
            try await resume()
        }
    }

    /// Jumps forward or back by `seconds`, or by the user's jump interval for that direction when
    /// `seconds` is `nil` or not positive.
    /// - Returns: The seconds jumped.
    /// - Throws: ``PlaybackIntentFailure/nothingPlaying`` when no item is loaded or restored.
    @discardableResult
    public func jump(forward: Bool, seconds: Int?) async throws(PlaybackIntentFailure) -> Int {
        guard playback.phase != .idle else { throw .nothingPlaying }
        let interval: Int
        if let seconds, seconds > 0 {
            interval = seconds
        } else {
            interval = forward ? settings.jumpForwardTime : settings.jumpBackwardsTime
        }
        await playback.jump(by: Double(forward ? interval : -interval))
        return interval
    }

    /// Starts a sleep timer, replacing any running one. Minutes are clamped to the sleep timer sheet's
    /// custom range (``SleepTimerPanelModel/customMinutesRange``).
    /// - Returns: The request as started, with the minutes clamped.
    /// - Throws: ``PlaybackIntentFailure/nothingPlaying`` when no item is loaded or restored,
    ///   ``PlaybackIntentFailure/sleepTimerUnavailable`` without a sleep timer or when it refuses the
    ///   length, and ``PlaybackIntentFailure/noChapterEnd`` when there's no chapter end ahead.
    @discardableResult
    public func setSleepTimer(_ request: PlaybackSleepRequest) throws(PlaybackIntentFailure) -> PlaybackSleepRequest {
        guard playback.phase != .idle else { throw .nothingPlaying }
        guard let sleepTimer else { throw .sleepTimerUnavailable }
        switch request {
        case .minutes(let minutes):
            let range = SleepTimerPanelModel.customMinutesRange
            let clamped = min(max(minutes, range.lowerBound), range.upperBound)
            guard sleepTimer.start(.duration(Double(clamped) * 60)) else { throw .sleepTimerUnavailable }
            return .minutes(clamped)
        case .endOfChapter:
            guard sleepTimer.start(.endOfChapter) else { throw .noChapterEnd }
            return .endOfChapter
        }
    }

    /// Sets and saves the playback rate, rounded to 0.1 and clamped to ``PlaybackSpeed/range``.
    /// - Returns: The rate set.
    /// - Throws: ``PlaybackIntentFailure/nothingPlaying`` when no item is loaded or restored.
    @discardableResult
    public func setSpeed(_ rate: Double) throws(PlaybackIntentFailure) -> Double {
        guard playback.phase != .idle else { throw .nothingPlaying }
        let rate = PlaybackSpeed.normalized(rate)
        playback.setRate(rate)
        return rate
    }
}
