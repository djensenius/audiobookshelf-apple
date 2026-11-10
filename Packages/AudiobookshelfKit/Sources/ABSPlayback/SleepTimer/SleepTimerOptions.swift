import ABSCore
import Foundation

/// What a sleep timer counts down to.
public enum SleepTimerMode: Sendable, Hashable {
    /// Pauses after this many seconds of playback. The countdown only runs while audio plays.
    case duration(TimeInterval)
    /// Pauses at the end of the chapter that is playing (the track, for media without chapters).
    case endOfChapter

    /// The mode for the `sleepTimerLength` setting: milliseconds, where `0` means end of chapter (legacy).
    public init(settingsLength milliseconds: Int) {
        self = milliseconds > 0 ? .duration(Double(milliseconds) / 1000) : .endOfChapter
    }
}

/// Sleep timer behaviour taken from the sleep timer settings in ``AppSettings``.
public struct SleepTimerOptions: Sendable, Hashable {
    /// Fades the volume out over the last ``SleepTimer/fadeDuration`` seconds (`disableSleepTimerFadeOut` off).
    public var fadesOut: Bool
    /// Plays a chime ``SleepTimer/chimeLeadTime`` seconds before the end (`enableSleepTimerAlmostDoneChime`).
    public var playsAlmostDoneChime: Bool
    /// Confirms a reset with feedback (`disableSleepTimerResetFeedback` off).
    public var playsResetFeedback: Bool
    /// The automatic timer (the `autoSleepTimer…` settings and `sleepTimerLength`).
    public var autoSleep: AutoSleepPolicy

    /// Defaults to the settings' defaults.
    public init(
        fadesOut: Bool = !AppSettings.Default.disableSleepTimerFadeOut,
        playsAlmostDoneChime: Bool = AppSettings.Default.enableSleepTimerAlmostDoneChime,
        playsResetFeedback: Bool = !AppSettings.Default.disableSleepTimerResetFeedback,
        autoSleep: AutoSleepPolicy = .disabled
    ) {
        self.fadesOut = fadesOut
        self.playsAlmostDoneChime = playsAlmostDoneChime
        self.playsResetFeedback = playsResetFeedback
        self.autoSleep = autoSleep
    }

    public init(settings: AppSettings.Snapshot) {
        self.init(
            fadesOut: !settings.disableSleepTimerFadeOut,
            playsAlmostDoneChime: settings.enableSleepTimerAlmostDoneChime,
            playsResetFeedback: !settings.disableSleepTimerResetFeedback,
            autoSleep: AutoSleepPolicy(settings: settings))
    }
}
