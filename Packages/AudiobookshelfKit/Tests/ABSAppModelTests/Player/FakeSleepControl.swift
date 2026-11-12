import ABSPlayback

/// Lets a ``SleepTimer`` control the same fake playback a ``PlayerViewModel`` reads, as the
/// coordinator serves both in the app. Seeks land at once, so there's never a seek in flight.
extension FakePlaybackControl: SleepTimerPlaybackControl {
    var pendingSeekTarget: Double? { nil }

    @discardableResult
    func play() -> Bool {
        guard playsStart else { return false }
        isPlaybackRequested = true
        isPlaying = true
        return true
    }

    func setVolume(_ volume: Float) {}
}
