import ABSCore

/// The span the scrubber shows: the whole timeline, or one chapter in chapter-track mode.
public struct TimelineRange: Sendable, Hashable {
    public let start: Double
    public let end: Double

    public var duration: Double { end - start }

    /// Seconds played inside the range, clamped to `0...duration`; NaN counts as the range start.
    public func elapsed(at time: Double) -> Double {
        min(max((time.isNaN ? start : time) - start, 0), duration)
    }

    /// Seconds left in the range, clamped to `0...duration`.
    public func remaining(at time: Double) -> Double {
        duration - elapsed(at: time)
    }

    /// Fraction played, `0...1`; `0` for an empty range.
    public func fraction(at time: Double) -> Double {
        duration > 0 ? elapsed(at: time) / duration : 0
    }

    /// Global time for a position inside the range (scrubbing, remote seek), clamped to the range;
    /// NaN counts as `0`.
    public func time(forElapsed elapsed: Double) -> Double {
        start + min(max(elapsed.isNaN ? 0 : elapsed, 0), duration)
    }
}

extension PlaybackTimeline {
    /// Previous-chapter restarts the current chapter when more than this many seconds have played.
    public static let previousChapterRestartThreshold: Double = 3

    /// Player clocks land slightly before a seek target (e.g. 1800.2499 after seeking to 1800.25).
    /// Chapter lookups treat a time this close before a chapter *start* as inside that chapter, like
    /// the legacy player's two-decimal rounding of chapter starts. Chapter ends are compared exactly,
    /// so only an adjacent chapter's start (not the end itself) moves the boundary.
    static let chapterBoundaryTolerance: Double = 0.01

    /// Index into ``chapters`` (the normalised list, not `session.chapters`) of the chapter playing
    /// at `time`, or `nil` in a gap, before the first chapter, or without chapters. UI and Now Playing
    /// "chapter n of N" must count ``chapters`` or match by `Chapter.id`.
    ///
    /// The last chapter stays current from its start to the end of the media, even when its end is
    /// short of the duration.
    public func currentChapterIndex(at time: Double) -> Int? {
        let time = clamp(time)
        guard let index = chapters.lastIndex(where: { $0.start <= time + Self.chapterBoundaryTolerance }) else {
            return nil
        }
        return time < chapters[index].end || index == chapters.count - 1 ? index : nil
    }

    public func currentChapter(at time: Double) -> Chapter? {
        currentChapterIndex(at: time).map { chapters[$0] }
    }

    /// Start of the first chapter after the one playing at `time`, or `nil` when there is none.
    public func nextChapterStart(from time: Double) -> Double? {
        let shifted = clamp(time) + Self.chapterBoundaryTolerance
        return chapters.first { $0.start > shifted }?.start
    }

    /// Where "previous chapter" goes from `time`.
    ///
    /// More than ``previousChapterRestartThreshold`` seconds into a chapter restarts it; otherwise
    /// it goes to the previous chapter (or restarts the first). In a gap the chapter before the gap
    /// counts as current. Before the first chapter, or without chapters, it goes to `0`.
    public func previousChapterStart(from time: Double) -> Double {
        let time = clamp(time)
        let shifted = time + Self.chapterBoundaryTolerance
        guard let index = chapters.lastIndex(where: { $0.start <= shifted }) else { return 0 }
        let chapter = chapters[index]
        if time - chapter.start > Self.previousChapterRestartThreshold || index == 0 {
            return chapter.start
        }
        return chapters[index - 1].start
    }

    /// The end of the chapter playing at `time`, for the end-of-chapter sleep timer; `nil` without a
    /// current chapter. For the last chapter this is the end of the media, so it is never in the past.
    public func endOfChapter(at time: Double) -> Double? {
        currentChapterRange(at: time)?.end
    }

    /// The scrubber range at `time`: the current chapter in chapter-track mode (the last chapter
    /// extends to the end of the media), otherwise, or with no current chapter, the whole timeline.
    public func progressRange(at time: Double, chapterTrack: Bool) -> TimelineRange {
        if chapterTrack, let range = currentChapterRange(at: time) {
            return range
        }
        return TimelineRange(start: 0, end: duration)
    }

    private func currentChapterRange(at time: Double) -> TimelineRange? {
        guard let index = currentChapterIndex(at: time) else { return nil }
        let chapter = chapters[index]
        let end = index == chapters.count - 1 ? max(chapter.end, duration) : chapter.end
        return TimelineRange(start: chapter.start, end: end)
    }
}
