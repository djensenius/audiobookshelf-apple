import ABSCore
import Foundation

/// The book's chapters, audio tracks and ebook files, for the tables under the description
/// (legacy `ChaptersTable.vue`, `TracksTable.vue` and `EbookFilesTable.vue`).
extension ItemDetailModel {
    /// A chapter. Rows built from the item have a finite ``start`` of at least `0` and a
    /// ``duration`` of at least `0`; ``ItemDetailModel/startTime(for:)`` clamps any row before
    /// playing it.
    public struct ChapterRow: Sendable, Hashable, Identifiable {
        public let id: Int
        /// The server's title; may be empty, and the view then numbers the chapter.
        public let title: String
        /// Seconds from the start of the book.
        public let start: TimeInterval
        /// Seconds; `max(0, end - start)`, as legacy (`ChaptersTable.vue:26`).
        public let duration: TimeInterval

        public init(id: Int, title: String, start: TimeInterval, duration: TimeInterval) {
            self.id = id
            self.title = title
            self.start = start
            self.duration = duration
        }
    }

    /// An audio track.
    public struct TrackRow: Sendable, Hashable, Identifiable {
        /// ``AudioTrack/id``.
        public let id: String
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

    /// Where to start playing `chapter`: its start, `0` when negative or not finite, and before
    /// the end of the book when its duration is known.
    public func startTime(for chapter: ChapterRow) -> TimeInterval {
        guard chapter.start.isFinite, chapter.start > 0 else { return 0 }
        if let duration = details?.duration, chapter.start >= duration {
            return max(0, duration.nextDown)
        }
        return chapter.start
    }

    // MARK: Mapping

    /// Sorted by start; chapters with the same start keep the server's order.
    static func chapterRows(book: Book) -> [ChapterRow] {
        let rows = (book.chapters ?? []).map { chapter in
            let start = nonNegative(chapter.start)
            return ChapterRow(
                id: chapter.id, title: chapter.title, start: start, duration: nonNegative(chapter.end - start))
        }
        return rows.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// Sorted by index; tracks without one follow, in the server's order.
    static func trackRows(book: Book) -> [TrackRow] {
        let rows = (book.tracks ?? []).map { track in
            TrackRow(
                id: track.id, index: track.index,
                name: nonBlank(track.metadata?.filename) ?? nonBlank(track.title),
                duration: nonNegative(track.duration))
        }
        return rows.enumerated()
            .sorted { ($0.element.index ?? .max, $0.offset) < ($1.element.index ?? .max, $1.offset) }
            .map(\.element)
    }

    /// The item's library files of type `ebook`, in the server's order.
    static func ebookFileRows(item: LibraryItem, book: Book) -> [EbookFileRow] {
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
