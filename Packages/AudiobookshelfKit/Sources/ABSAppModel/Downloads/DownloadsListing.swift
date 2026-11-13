import ABSCore
import ABSData
import Foundation

/// What the Downloads tab shows for one server connection: its downloaded books and podcasts
/// (legacy `pages/downloads.vue`), and the downloads under way (legacy `pages/downloading.vue`
/// and `DownloadProgressIndicator.vue`). A pure value, built from the stored local items and
/// ``DownloadsController``'s records and progress.
///
/// - Books and podcasts are sorted by title, as Finder sorts names; a podcast lists its
///   downloaded episodes, newest first, each with the size of its files.
/// - An item's size is the sum of its audio and ebook files (the cover isn't a local file).
/// - Downloads keep the controller's order (oldest first). Their fraction is the live progress
///   when there is any, else what the record's parts have written.
public struct DownloadsListing: Sendable, Equatable {
    /// A downloaded library item.
    public struct Item: Sendable, Equatable, Identifiable {
        /// The local item's ID.
        public var id: UUID
        public var serverConnectionID: UUID
        public var libraryItemId: String
        public var mediaType: MediaType
        public var title: String
        public var author: String?
        public var coverUpdatedAt: Date?
        public var byteCount: Int64
        /// A book's downloaded audio files.
        public var trackCount: Int
        public var hasEbook: Bool
        /// A podcast's downloaded episodes; empty for a book.
        public var episodes: [Episode]
    }

    /// A downloaded podcast episode.
    public struct Episode: Sendable, Equatable, Identifiable {
        /// The server's episode ID.
        public var id: String
        public var title: String
        public var publishedAt: Date?
        public var byteCount: Int64
    }

    /// A download under way.
    public struct Download: Sendable, Equatable, Identifiable {
        /// The download record's ID.
        public var id: UUID
        /// The book, or the episode.
        public var title: String
        /// The podcast of an episode; `nil` for a book.
        public var subtitle: String?
        public var status: Status
        public var bytesWritten: Int64
        public var expectedBytes: Int64
    }

    /// A download's row state, from its record's ``DownloadState``.
    public enum Status: Sendable, Equatable {
        case queued
        /// With the fraction done, from 0 to 1.
        case downloading(Double)
        case paused(Double)
        /// Failed for good; the user retries it.
        case failed

        /// Whether ``DownloadsTabModel/retry(recordID:)`` applies.
        public var isRetryable: Bool {
            switch self {
            case .paused, .failed: true
            case .queued, .downloading: false
            }
        }
    }

    public var books: [Item]
    public var podcasts: [Item]
    public var downloads: [Download]
    /// The size of every listed book and podcast.
    public var downloadedBytes: Int64

    public var isEmpty: Bool { books.isEmpty && podcasts.isEmpty && downloads.isEmpty }

    /// How much of ``downloads`` is done, from 0 to 1, by bytes (legacy
    /// `DownloadProgressIndicator.vue`); 0 while no size is known.
    public var downloadingFraction: Double {
        let expected = downloads.reduce(Int64(0)) { $0 + $1.expectedBytes }
        guard expected > 0 else { return 0 }
        let written = downloads.reduce(Int64(0)) { $0 + min($1.bytesWritten, $1.expectedBytes) }
        return Double(written) / Double(expected)
    }

    /// - Parameters:
    ///   - items: the stored local items; those of other connections are left out.
    ///   - records: ``DownloadsController/records``; those of other connections are left out.
    ///   - progress: ``DownloadsController/progress``.
    ///   - serverConnectionID: the signed-in connection; `nil` lists nothing.
    public init(
        items: [LocalLibraryItemDTO], records: [DownloadRecordDTO], progress: [UUID: DownloadsController.Progress],
        serverConnectionID: UUID?
    ) {
        let listed = items.filter { $0.serverConnectionID == serverConnectionID }.map(Self.item).sorted(
            by: Self.byTitle)
        books = listed.filter { $0.mediaType != .podcast }
        podcasts = listed.filter { $0.mediaType == .podcast }
        downloads = records.filter { $0.key.serverConnectionID == serverConnectionID }.map {
            Self.download($0, progress: progress[$0.id])
        }
        downloadedBytes = listed.reduce(0) { $0 + $1.byteCount }
    }

    /// The row state of `record`, with its live `progress` if any.
    public static func status(of record: DownloadRecordDTO, progress: DownloadsController.Progress?) -> Status {
        switch record.state {
        case .queued: .queued
        case .downloading: .downloading(fraction(of: record, progress: progress))
        case .paused: .paused(fraction(of: record, progress: progress))
        case .failed: .failed
        }
    }

    // MARK: - Building

    private static func item(_ item: LocalLibraryItemDTO) -> Item {
        Item(
            id: item.id, serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId,
            mediaType: item.mediaType, title: item.title, author: item.authorName, coverUpdatedAt: item.coverUpdatedAt,
            byteCount: item.files.reduce(0) { $0 + max($1.size, 0) },
            trackCount: item.files.count { $0.kind == .audio }, hasEbook: item.files.contains { $0.kind == .ebook },
            episodes: item.mediaType == .podcast ? episodes(of: item) : [])
    }

    /// The snapshot's episodes, plus any whose files have no entry in it.
    private static func episodes(of item: LocalLibraryItemDTO) -> [Episode] {
        var bytes: [String: Int64] = [:]
        var filenames: [String: String] = [:]
        for file in item.files {
            guard let id = file.episodeId else { continue }
            bytes[id, default: 0] += max(file.size, 0)
            filenames[id] = filenames[id] ?? file.filename
        }
        var episodes = item.media.episodes.map {
            Episode(id: $0.id, title: $0.title, publishedAt: $0.publishedAt, byteCount: bytes[$0.id] ?? 0)
        }
        let known = Set(episodes.map(\.id))
        for (id, filename) in filenames where !known.contains(id) {
            episodes.append(Episode(id: id, title: filename, publishedAt: nil, byteCount: bytes[id] ?? 0))
        }
        return episodes.sorted { lhs, rhs in
            switch (lhs.publishedAt, rhs.publishedAt) {
            case (let left?, let right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private static func download(_ record: DownloadRecordDTO, progress: Progress?) -> Download {
        let episode = record.key.episodeId.map { id in record.media.episodes.first { $0.id == id }?.title ?? id }
        let written = record.parts.reduce(Int64(0)) { $0 + max($1.bytesWritten, 0) }
        return Download(
            id: record.id, title: episode ?? record.title, subtitle: episode == nil ? nil : record.title,
            status: status(of: record, progress: progress),
            bytesWritten: progress.map { max($0.bytes, written) } ?? written,
            expectedBytes: record.parts.reduce(0) { $0 + max($1.expectedBytes, 0) })
    }

    private typealias Progress = DownloadsController.Progress

    private static func fraction(of record: DownloadRecordDTO, progress: Progress?) -> Double {
        if let progress { return min(max(progress.fraction, 0), 1) }
        let expected = record.parts.reduce(Int64(0)) { $0 + max($1.expectedBytes, 0) }
        guard expected > 0 else { return 0 }
        let written = record.parts.reduce(Int64(0)) { $0 + min(max($1.bytesWritten, 0), max($1.expectedBytes, 0)) }
        return Double(written) / Double(expected)
    }

    private static func byTitle(_ lhs: Item, _ rhs: Item) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
