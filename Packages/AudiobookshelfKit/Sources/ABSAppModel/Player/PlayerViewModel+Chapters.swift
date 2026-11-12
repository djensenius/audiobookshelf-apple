import ABSCore
import ABSPlayback

/// One chapter in the player's chapter list.
public struct PlayerChapterRow: Sendable, Hashable, Identifiable {
    /// The index into the normalised ``ABSPlayback/PlaybackTimeline/chapters``; the server's
    /// chapter IDs may repeat.
    public let id: Int
    /// The server's title; empty when it has none.
    public let title: String
    /// Media seconds.
    public let start: Double
    /// Media seconds, never negative.
    public let duration: Double

    public init(id: Int, chapter: Chapter) {
        self.id = id
        title = chapter.title
        start = chapter.start
        duration = max(0, chapter.end - chapter.start)
    }
}

extension PlayerViewModel {
    /// The current item's chapters: the loaded timeline's, else the session's while the media loads;
    /// empty without either (a restored record has no chapters).
    public var chapters: [PlayerChapterRow] {
        guard let timeline = chapterTimeline else { return [] }
        return timeline.chapters.enumerated().map { PlayerChapterRow(id: $0.offset, chapter: $0.element) }
    }

    public var hasChapters: Bool { chapterTimeline.map { !$0.chapters.isEmpty } ?? false }

    /// The ``PlayerChapterRow/id`` of the chapter playing now; `nil` in a gap, before the first
    /// chapter or without chapters. Reads the playback time, so read it only in a small leaf view.
    public var currentChapterIndex: Int? {
        chapterTimeline?.currentChapterIndex(at: playback.currentTime)
    }

    /// Seeks to the chapter's start without changing play or pause, as legacy `selectChapter`.
    public func selectChapter(_ row: PlayerChapterRow) async {
        await playback.seek(to: row.start)
    }

    /// The loaded timeline, else one built from the session (the coordinator's `.starting` phase).
    private var chapterTimeline: PlaybackTimeline? {
        if let timeline = playback.timeline { return timeline }
        return playback.session.map(PlaybackTimeline.init(session:))
    }
}
