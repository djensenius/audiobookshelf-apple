import ABSPlayback
import Foundation

/// The sleep timer sheet's state and commands (port of `SleepTimerModal.vue`), over a ``SleepTimer`` and the
/// player it controls. Holds no state of its own: everything is read from the timer and the player when asked,
/// so views can make one per body.
///
/// ``state`` doesn't change as the countdown ticks; ``remaining`` and ``offersEndOfChapter`` do (they read the
/// countdown and the playback time), so read them only in small leaf views. Not `@Observable`: it stores no
/// state, and views observe the timer and the player through it.
@MainActor
public final class SleepTimerPanelModel {
    /// What the running timer's −/+ buttons subtract and add, in seconds (D15).
    public static let adjustment: TimeInterval = 300
    /// The duration presets, in minutes: legacy's (``SettingsViewModel/durationPresetMinutes``) up to two hours, as
    /// #58 asks. Settings keeps legacy's list, so a stored length still matches its presets.
    public static let presetMinutes = SettingsViewModel.durationPresetMinutes + [120]
    /// The custom time stepper's range, in minutes, as in Settings.
    public static let customMinutesRange = SettingsViewModel.customMinutesRange

    /// The sheet's state, ignoring the countdown.
    public enum State: Equatable, Sendable {
        /// No timer runs.
        case idle
        /// A timer runs; `isAutomatic` when the auto sleep timer started it.
        case running(isAutomatic: Bool, isEndOfChapter: Bool)
        /// The timer recently paused playback and ``restart()`` would restart it (the grace period);
        /// `isAutomatic` when the auto sleep timer had started it.
        case restartable(isAutomatic: Bool)
    }

    /// The timer a cancel confirmation was opened for, so confirming acts on that timer only (``confirmCancel(_:)``).
    public struct CancelRequest: Equatable, Sendable {
        /// The timer's ``SleepTimer/runIdentity``.
        public let identity: Int
        /// Whether it was the automatic timer, which confirming suppresses even once it has ended.
        public let isAutomatic: Bool
    }

    public let timer: SleepTimer
    private let player: PlayerViewModel

    public init(timer: SleepTimer, player: PlayerViewModel) {
        self.timer = timer
        self.player = player
    }

    public var state: State {
        if let mode = timer.mode {
            return .running(isAutomatic: timer.isAutomatic, isEndOfChapter: mode == .endOfChapter)
        }
        return timer.canRestart ? .restartable(isAutomatic: timer.canRestartAutomatic) : .idle
    }

    /// Seconds until the running timer pauses playback; `nil` when none runs. Changes every tick.
    public var remaining: TimeInterval? { timer.remaining }

    /// Whether End of Chapter is offered: the loaded item has a chapter playing (D16). Reads the playback time.
    public var offersEndOfChapter: Bool {
        player.playback.timeline?.endOfChapter(at: player.playback.currentTime) != nil
    }

    /// Whether shake to reset is on, for the sheet's hint (D17). The timer only detects shakes on iOS.
    public var shakeToResetEnabled: Bool { timer.options.shakeSensitivity != nil }

    /// Starts a timer of `minutes`, clamped to ``customMinutesRange``, replacing any running one.
    @discardableResult
    public func start(minutes: Int) -> Bool {
        let minutes = min(max(minutes, Self.customMinutesRange.lowerBound), Self.customMinutesRange.upperBound)
        return timer.start(.duration(TimeInterval(minutes) * 60))
    }

    /// Starts an end-of-chapter timer. `false` when there's no chapter or track end ahead (playback is at the end
    /// of the media; with under 10 seconds of the last chapter left it stops at the end of the media), for the
    /// sheet to say so rather than hide the option (D16).
    @discardableResult
    public func startEndOfChapter() -> Bool {
        timer.start(.endOfChapter)
    }

    /// Adds ``adjustment`` to the running timer.
    public func add() {
        timer.add(Self.adjustment)
    }

    /// Subtracts ``adjustment`` from the running timer, leaving at least a second.
    public func subtract() {
        timer.subtract(Self.adjustment)
    }

    /// Whether cancelling needs confirming: cancelling the automatic timer, running or restartable, keeps it off
    /// until its window ends (D18, `MessageConfirmDisableAutoTimer`).
    public var needsCancelConfirmation: Bool { timer.isAutomatic || timer.canRestartAutomatic }

    /// Cancels the running timer, or ends the grace period of one that expired.
    public func cancel() {
        timer.cancel()
    }

    /// What a cancel confirmation opened now is about; `nil` when no timer runs or can restart.
    public func cancelRequest() -> CancelRequest? {
        timer.runIdentity.map { CancelRequest(identity: $0, isAutomatic: needsCancelConfirmation) }
    }

    /// Cancels the timer `request` was made for if it's still running or in its grace period, never a newer one
    /// (another window may have started one while the confirmation was open). For the automatic timer, once it has
    /// ended, it still keeps it off until its window ends, as the confirmation said it would.
    public func confirmCancel(_ request: CancelRequest) {
        guard !timer.cancel(identity: request.identity), request.isAutomatic else { return }
        timer.suppressAutomaticTimer()
    }

    /// Whether Restart is offered in the ``State/restartable(isAutomatic:)`` state: not once the grace period is
    /// over, nor for an end-of-chapter timer at the end of the media, where it couldn't restart. Reads the playback
    /// position, which stays put while the timer has paused playback.
    public var offersRestart: Bool { timer.isRestartAvailable }

    /// Restarts the timer that recently expired and waits for playback to resume. ``SleepTimer/RestartResult/
    /// unavailable`` when the grace period is over (which ``state`` may not show yet: the timer notices at its next
    /// turn on the main actor) or the timer can't restart; ``SleepTimer/RestartResult/failed`` when the rewind didn't
    /// land, which brings the grace period back.
    public func restart() async -> SleepTimer.RestartResult {
        await timer.restart()
    }
}
