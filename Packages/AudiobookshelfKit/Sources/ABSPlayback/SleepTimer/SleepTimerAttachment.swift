import ABSCore
import Foundation
import Observation

/// Connects a ``SleepTimer`` to a ``PlaybackCoordinator`` and keeps the timer's options in step with ``AppSettings``.
///
/// - Installs the coordinator's ``PlaybackCoordinator/willResume`` hook, which calls
///   ``SleepTimer/playbackWillStart(at:)``. The hook has one owner: a later attachment on the same coordinator replaces
///   this one's, and any other feature that needs it must chain through the attachment's hook.
/// - Passes item changes, landed seeks, pauses and the end of the media to the timer. The coordinator delivers the
///   end before it advances to another item, so a timer that pauses there cancels the advance.
/// - Applies changes to the sleep timer settings as they happen.
///
/// Create one per coordinator and keep it while the coordinator can play. ``detach()``, or releasing the attachment,
/// disconnects and cancels the timer.
@MainActor
public final class SleepTimerAttachment {
    public let timer: SleepTimer
    private weak var coordinator: PlaybackCoordinator?
    private let settings: AppSettings
    private let now: @Sendable () -> Date
    private var observerToken: PlaybackObserverToken?
    /// Owns the coordinator's `willResume`. The coordinator holds it weakly; unlike `self`, it is still alive in `deinit`.
    private let hookOwner = HookOwner()
    private var isDetached = false

    /// - Parameters:
    ///   - feedback: Plays the chime and the reset feedback; `nil` plays nothing.
    ///   - shakeDetector: Detects shake to reset; `nil` disables it. Defaults to ``platformShakeDetector()``.
    ///   - now: The wall-clock time that decides whether playback starts inside the automatic timer's window.
    ///   - tickInterval: How often the countdown, fade and chime update (``SleepTimer``'s default).
    public init(
        coordinator: PlaybackCoordinator,
        settings: AppSettings,
        feedback: (any SleepTimerFeedback)? = SystemSleepTimerFeedback(),
        shakeDetector: (any ShakeDetecting)? = SleepTimerAttachment.platformShakeDetector(),
        clock: any Clock<Duration> = ContinuousClock(),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { .now },
        tickInterval: Duration = .milliseconds(500)
    ) {
        self.coordinator = coordinator
        self.settings = settings
        self.now = now
        timer = SleepTimer(
            control: coordinator, feedback: feedback, shakeDetector: shakeDetector,
            options: Self.options(from: settings), clock: clock, calendar: calendar, tickInterval: tickInterval)
        let timer = timer
        // The timer's own pause on `.ended` is delivered after `.ended`, and would end the grace period it opened.
        var pausedAtEnd = false
        observerToken = coordinator.addObserver { [weak timer] event in
            switch event {
            case .itemChanged(let key): timer?.itemDidChange(key?.rawValue)
            case .didSeek(let time): timer?.didSeek(to: time)
            case .paused where pausedAtEnd: pausedAtEnd = false
            case .paused: timer?.playbackDidPause()
            case .ended: pausedAtEnd = timer?.playbackDidEnd() == true
            default: break
            }
        }
        coordinator.setWillResume(
            { [weak self] in
                guard let self, !isDetached else { return 0 }
                return self.timer.playbackWillStart(at: self.now())
            }, owner: hookOwner)
        trackSettings()
    }

    isolated deinit {
        detach()
    }

    /// `ShakeDetector` on iOS; `nil` on macOS, which has no accelerometer.
    public static func platformShakeDetector() -> (any ShakeDetecting)? {
        #if os(iOS)
            ShakeDetector()
        #else
            nil
        #endif
    }

    /// Stops passing events to the timer, removes the `willResume` hook unless another owner has replaced it, and
    /// cancels the timer. Idempotent.
    public func detach() {
        guard !isDetached else { return }
        isDetached = true
        if let coordinator {
            if let observerToken { coordinator.removeObserver(observerToken) }
            coordinator.clearWillResume(ownedBy: hookOwner)
        }
        observerToken = nil
        timer.cancel(at: now())
    }

    private func trackSettings() {
        guard !isDetached else { return }
        let options = withObservationTracking {
            Self.options(from: settings)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackSettings() }
        }
        if timer.options != options { timer.options = options }
    }

    /// Reads every sleep timer setting, so that observation tracks them, then converts the stored snapshot, which
    /// `AppSettings` writes before the change is applied here.
    private static func options(from settings: AppSettings) -> SleepTimerOptions {
        _ = (
            settings.sleepTimerLength, settings.disableShakeToResetSleepTimer, settings.shakeSensitivity,
            settings.disableSleepTimerFadeOut, settings.disableSleepTimerResetFeedback,
            settings.enableSleepTimerAlmostDoneChime, settings.autoSleepTimer, settings.autoSleepTimerStartTime,
            settings.autoSleepTimerEndTime, settings.autoSleepTimerAutoRewind, settings.autoSleepTimerAutoRewindTime
        )
        return SleepTimerOptions(settings: AppSettings.snapshot(from: settings.defaults))
    }

    private final class HookOwner {}
}
