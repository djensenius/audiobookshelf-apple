/// The sounds and vibrations of a ``SleepTimer``. The playback coordinator (#52) injects the system's (#147).
@MainActor
public protocol SleepTimerFeedback: AnyObject {
    /// The almost-done chime, ``SleepTimer/chimeLeadTime`` seconds before the timer pauses playback.
    func playChime()
    /// Confirms that ``SleepTimer/reset()`` restarted the timer.
    func playResetFeedback()
}
