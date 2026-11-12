import ABSAPI
import ABSCore
import Foundation

/// The book's chapters, audio tracks and ebook files, for the tables under the description
/// (legacy `ChaptersTable.vue`, `TracksTable.vue` and `EbookFilesTable.vue`).
extension ItemDetailModel {
    /// A chapter. Rows built from the item have a finite ``start`` of at least `0` and a
    /// ``duration`` of at least `0`; ``ItemDetailModel/startTime(for:)`` clamps any row before
    /// playing it.
    public struct ChapterRow: Sendable, Hashable, Identifiable {
        /// The row's 0-based position in ``ItemDetailModel/chapters``. The server's chapter IDs
        /// may repeat, so they can't identify rows.
        public let id: Int
        /// The server's ``Chapter/id``.
        public let chapterID: Int
        /// The server's title; may be empty, and the view then numbers the chapter.
        public let title: String
        /// Seconds from the start of the book.
        public let start: TimeInterval
        /// Seconds; `max(0, end - start)`, as legacy (`ChaptersTable.vue:26`).
        public let duration: TimeInterval

        public init(id: Int, chapterID: Int, title: String, start: TimeInterval, duration: TimeInterval) {
            self.id = id
            self.chapterID = chapterID
            self.title = title
            self.start = start
            self.duration = duration
        }
    }

    /// An audio track.
    public struct TrackRow: Sendable, Hashable, Identifiable {
        /// The row's 0-based position in ``ItemDetailModel/tracks``. ``AudioTrack/id`` repeats
        /// when tracks have neither an index nor a start offset, so it can't identify rows.
        public let id: Int
        /// ``AudioTrack/id``.
        public let trackID: String
        /// 1-based; `nil` when the server didn't send one.
        public let index: Int?
        /// The file name, else the track title; `nil` (shown as Unknown) when both are blank, as
        /// legacy (`TracksTable.vue:22`).
        public let name: String?
        /// Seconds, at least `0`.
        public let duration: TimeInterval
    }

    /// A library file of type `ebook`, primary or supplementary.
    public struct EbookFileRow: Sendable, Hashable, Identifiable {
        /// The file's inode, ``LibraryFile/ino``.
        public let id: String
        /// May be empty when the server sent no file metadata.
        public let filename: String
        /// From the file's extension, matched case-insensitively; `nil` without an extension.
        public let format: EbookFormat?
        /// Bytes.
        public let size: Int?
        /// The book's main ebook (``Book/ebookFile``); the others are supplementary.
        public let isPrimary: Bool
    }

    /// Chapters can be played: the book has audio (``hasAudio``). The view also needs a
    /// `playItem` action and no start in progress.
    public var canPlayChapters: Bool { hasAudio }

    /// Where to start playing `chapter` once the user confirms it, or `nil` when that's no longer
    /// right because the item changed while they were asked: it can't play chapters anymore
    /// (``canPlayChapters``), the server says it's gone (a 404, kept while retrying), or the
    /// chapter at that position isn't the same anymore. The view also checks its own state
    /// (a `playItem` action, no start in progress).
    public func chapterToPlay(confirming chapter: ChapterRow) -> TimeInterval? {
        guard canPlayChapters, (error as? APIError) != .notFound,
            chapters.indices.contains(chapter.id), chapters[chapter.id] == chapter
        else { return nil }
        return startTime(for: chapter)
    }

    /// Where to start playing `chapter`: its start, `0` when negative or not finite, and
    /// ``endMargin`` before the end of the book when its duration is known.
    public func startTime(for chapter: ChapterRow) -> TimeInterval {
        guard chapter.start.isFinite, chapter.start > 0 else { return 0 }
        if let duration = details?.duration, chapter.start > duration - Self.endMargin {
            return max(0, duration - Self.endMargin)
        }
        return chapter.start
    }

    /// How far before the end of the book a clamped start is. The engine seeks in whole
    /// milliseconds, so anything closer could round to the end and finish at once.
    public static let endMargin: TimeInterval = 0.001

    // MARK: Mapping

    /// Sorted by start; chapters with the same start keep the server's order.
    static func chapterRows(book: Book) -> [ChapterRow] {
        let sorted = (book.chapters ?? []).enumerated()
            .map { (chapter: $0.element, start: nonNegative($0.element.start), offset: $0.offset) }
            .sorted { ($0.start, $0.offset) < ($1.start, $1.offset) }
        return sorted.enumerated().map { position, entry in
            ChapterRow(
                id: position, chapterID: entry.chapter.id, title: entry.chapter.title, start: entry.start,
                duration: nonNegative(entry.chapter.end - entry.start))
        }
    }

    /// Sorted by index; tracks without one follow, in the server's order.
    static func trackRows(book: Book) -> [TrackRow] {
        let sorted = (book.tracks ?? []).enumerated()
            .sorted { ($0.element.index ?? .max, $0.offset) < ($1.element.index ?? .max, $1.offset) }
            .map(\.element)
        return sorted.enumerated().map { position, track in
            TrackRow(
                id: position, trackID: track.id, index: track.index,
                name: nonBlank(track.metadata?.filename) ?? nonBlank(track.title),
                duration: nonNegative(track.duration))
        }
    }

    /// The item's library files of type `ebook`, in the server's order.
    static func ebookFileRows(item: LibraryItem, book: Book) -> [EbookFileRow] {
        // Per #341 the primary is the book's `ebookFile`, unlike legacy's `!isSupplementary`.
        let primary = book.ebookFile?.ino
        return (item.libraryFiles ?? []).filter { $0.fileType == "ebook" }.map { file in
            EbookFileRow(
                id: file.ino, filename: file.metadata?.filename ?? "", format: format(ext: file.metadata?.ext),
                size: file.metadata?.size, isPrimary: file.ino == primary)
        }
    }

    /// `".EPUB"` or `"epub"` is ``EbookFormat/epub``; a blank extension is `nil`.
    private static func format(ext: String?) -> EbookFormat? {
        guard let ext else { return nil }
        let trimmed = ext.trimmingCharacters(in: .whitespaces)
        let name = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return name.isEmpty ? nil : EbookFormat(rawValue: name)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func nonNegative(_ seconds: Double) -> TimeInterval {
        seconds.isFinite ? max(seconds, 0) : 0
    }
}
