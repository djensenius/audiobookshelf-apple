import ABSPlayback
import Foundation
import Observation

/// The sleep timer sheet's state and commands (port of `SleepTimerModal.vue`), over a ``SleepTimer`` and the
/// player it controls. Holds no state of its own: everything is read from the timer and the player when asked,
/// so views can make one per body.
///
/// ``state`` doesn't change as the countdown ticks; ``remaining`` and ``offersEndOfChapter`` do (they read the
/// countdown and the playback time), so read them only in small leaf views.
@MainActor
@Observable
public final class SleepTimerPanelModel {
    /// What the running timer's −/+ buttons subtract and add, in seconds (D15).
    public static let adjustment: TimeInterval = 300
    /// The duration presets, in minutes: legacy's (``SettingsViewModel/durationPresetMinutes``) up to two hours.
    public static let presetMinutes = SettingsViewModel.durationPresetMinutes + [120]
    /// The custom time stepper's range, in minutes, as in Settings.
    public static let customMinutesRange = SettingsViewModel.customMinutesRange

    /// The sheet's state, ignoring the countdown.
    public enum State: Equatable, Sendable {
        /// No timer runs.
        case idle
        /// A timer runs; `isAutomatic` when the auto sleep timer started it.
        case running(isAutomatic: Bool, isEndOfChapter: Bool)
        /// The timer recently paused playback and ``restart()`` would restart it (the grace period).
        case restartable
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
        return timer.canRestart ? .restartable : .idle
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

    /// Starts an end-of-chapter timer. `false` when there's no chapter end ahead (under 10 seconds left and no
    /// next chapter), for the sheet to say so rather than hide the option (D16).
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

    /// Whether cancelling needs confirming: cancelling the automatic timer keeps it off until its window ends
    /// (D18, `MessageConfirmDisableAutoTimer`).
    public var needsCancelConfirmation: Bool { timer.isAutomatic }

    public func cancel() {
        timer.cancel()
    }

    /// Restarts the timer that recently expired, resuming playback. `false` when the grace period is over.
    @discardableResult
    public func restart() -> Bool {
        timer.reset()
    }
}
