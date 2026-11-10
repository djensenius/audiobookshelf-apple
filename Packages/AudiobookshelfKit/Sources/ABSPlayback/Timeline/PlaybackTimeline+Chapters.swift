import ABSCore

/// The span the scrubber shows: the whole timeline, or one chapter in chapter-track mode.
public struct TimelineRange: Sendable, Hashable {
    public let start: Double
    public let end: Double

    public var duration: Double { end - start }

    /// Seconds played inside the range, clamped to `0...duration`.
    public func elapsed(at time: Double) -> Double {
        min(max((PlaybackTimeline.finite(time) ?? start) - start, 0), duration)
    }

    /// Seconds left in the range, clamped to `0...duration`.
    public func remaining(at time: Double) -> Double {
        duration - elapsed(at: time)
    }

    /// Fraction played, `0...1`; `0` for an empty range.
    public func fraction(at time: Double) -> Double {
        duration > 0 ? elapsed(at: time) / duration : 0
    }

    /// Global time for a position inside the range (scrubbing, remote seek), clamped to the range.
    public func time(forElapsed elapsed: Double) -> Double {
        start + min(max(PlaybackTimeline.finite(elapsed) ?? 0, 0), duration)
    }
}

extension PlaybackTimeline {
    /// Previous-chapter restarts the current chapter when more than this many seconds have played.
    public static let previousChapterRestartThreshold: Double = 3

    /// Player clocks land slightly before a seek target (e.g. 1800.2499 after seeking to 1800.25).
    /// Chapter lookups treat a time this close to a chapter start as inside that chapter, like the
    /// legacy player's two-decimal rounding of chapter starts.
    static let chapterBoundaryTolerance: Double = 0.01

    /// Index into ``chapters`` of the chapter playing at `time`, or `nil` in a gap, before the first
    /// chapter, or without chapters. At the very end the last chapter stays current when it reaches
    /// the end of the media.
    public func currentChapterIndex(at time: Double) -> Int? {
        let time = clamp(time)
        let shifted = time + Self.chapterBoundaryTolerance
        guard let index = chapters.lastIndex(where: { $0.start <= shifted }) else { return nil }
        if shifted < chapters[index].end { return index }
        let isLast = index == chapters.count - 1
        return isLast && duration > 0 && chapters[index].end >= duration && time >= duration ? index : nil
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
    /// current chapter.
    public func endOfChapter(at time: Double) -> Double? {
        currentChapter(at: time)?.end
    }

    /// The scrubber range at `time`: the current chapter in chapter-track mode, otherwise (or with
    /// no current chapter) the whole timeline.
    public func progressRange(at time: Double, chapterTrack: Bool) -> TimelineRange {
        if chapterTrack, let chapter = currentChapter(at: time) {
            return TimelineRange(start: chapter.start, end: chapter.end)
        }
        return TimelineRange(start: 0, end: duration)
    }
}
