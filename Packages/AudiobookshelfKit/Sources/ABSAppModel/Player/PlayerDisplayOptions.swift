import ABSCore

/// One track as the player shows it: the fraction played and the elapsed and remaining times.
public struct PlayerTrackTimes: Sendable, Hashable {
    /// The fraction of the track played, `0...1`, in media time.
    public var progress: Double
    /// Seconds played, divided by the rate when ``PlayerDisplayOptions/scalesElapsedTimeBySpeed``
    /// is on.
    public var elapsed: Double
    /// Seconds left at the current rate (wall-clock time), whatever the options.
    public var remaining: Double

    public init(progress: Double, elapsed: Double, remaining: Double) {
        self.progress = progress
        self.elapsed = elapsed
        self.remaining = remaining
    }
}

/// The full player's display options from its menu (port of the legacy `playerSettings` in
/// `components/app/AudioPlayer.vue`), and the rules that follow from them. Stored per device in
/// ``AppSettings``.
///
/// - **Chapter and total track.** At least one is always on, as in legacy: turning one off turns
///   the other on. With both on and a chapter playing, the player shows the whole item's track
///   alongside the chapter's.
/// - **Speed scaling.** The elapsed time is divided by the rate when
///   ``scalesElapsedTimeBySpeed`` is on; the remaining time always is (legacy `timeRemaining`).
/// - **Lock.** ``isLocked`` hides the jump and chapter buttons and the scrubber's thumb, and
///   refuses scrubbing; play/pause stays.
public struct PlayerDisplayOptions: Sendable, Hashable {
    public var chapterTrack: Bool
    public var totalTrack: Bool
    public var scalesElapsedTimeBySpeed: Bool
    public var isLocked: Bool

    public init(chapterTrack: Bool, totalTrack: Bool, scalesElapsedTimeBySpeed: Bool, isLocked: Bool) {
        self.chapterTrack = chapterTrack
        self.totalTrack = totalTrack
        self.scalesElapsedTimeBySpeed = scalesElapsedTimeBySpeed
        self.isLocked = isLocked
    }

    /// Toggles the chapter track; turning it off turns the total track on (legacy `chapter_track`).
    public mutating func toggleChapterTrack() {
        chapterTrack.toggle()
        if !chapterTrack { totalTrack = true }
    }

    /// Toggles the total track; turning it off turns the chapter track on (legacy `total_track`).
    public mutating func toggleTotalTrack() {
        totalTrack.toggle()
        if !totalTrack { chapterTrack = true }
    }

    /// Whether the jump and previous/next chapter buttons show.
    public var showsSkipControls: Bool { !isLocked }

    /// Whether the scrubber shows its thumb and can be dragged.
    public var allowsScrubbing: Bool { !isLocked }

    /// Whether the whole item's track shows alongside the main one: both tracks are on and the main
    /// one shows a chapter. Without a chapter the main track already is the whole item.
    public func showsTotalTrack(mainTrackIsChapter: Bool) -> Bool {
        chapterTrack && totalTrack && mainTrackIsChapter
    }

    /// The times shown for `elapsed` media seconds of a `duration`-second track at `rate`. A
    /// non-finite or non-positive rate counts as `1`; `elapsed` is clamped to the track.
    public func times(elapsed: Double, duration: Double, rate: Double) -> PlayerTrackTimes {
        let duration = duration.isFinite ? max(duration, 0) : 0
        let elapsed = elapsed.isFinite ? min(max(elapsed, 0), duration) : 0
        let rate = rate.isFinite && rate > 0 ? rate : 1
        return PlayerTrackTimes(
            progress: duration > 0 ? elapsed / duration : 0,
            elapsed: scalesElapsedTimeBySpeed ? elapsed / rate : elapsed,
            remaining: (duration - elapsed) / rate)
    }
}

extension PlayerDisplayOptions {
    /// The options stored in `settings`.
    @MainActor
    init(_ settings: AppSettings) {
        self.init(
            chapterTrack: settings.chapterTrack, totalTrack: settings.totalTrack,
            scalesElapsedTimeBySpeed: settings.scaleElapsedTimeBySpeed, isLocked: settings.lockPlayer)
    }

    /// Stores the options in `settings`, writing only the ones that changed.
    @MainActor
    func save(to settings: AppSettings) {
        if settings.chapterTrack != chapterTrack { settings.chapterTrack = chapterTrack }
        if settings.totalTrack != totalTrack { settings.totalTrack = totalTrack }
        if settings.scaleElapsedTimeBySpeed != scalesElapsedTimeBySpeed {
            settings.scaleElapsedTimeBySpeed = scalesElapsedTimeBySpeed
        }
        if settings.lockPlayer != isLocked { settings.lockPlayer = isLocked }
    }
}
