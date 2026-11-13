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
/// - Downloads keep the controller's order (oldest first). Their bytes are the live progress
///   when there is any, with the expected size the transfers have learned, else what the
///   record's parts have written of their stored sizes; a row's fraction, its byte label and
///   ``downloadingFraction`` all use these bytes.
/// - Sizes come from the server: byte totals saturate at `Int64.max`, and fractions are summed as
///   `Double`, as `DownloadManager` sums them, so no size can overflow.
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

        /// The cover's `updatedAt` for its ``CoverRef``, as ``LocalDownloadedCovers`` reads it;
        /// `nil` when unknown or out of range.
        public var coverVersion: Int? { LocalDownloadedCovers.version(of: coverUpdatedAt) }
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
        /// The live expected size when the transfers have learned it, else the stored one; 0
        /// while no size is known.
        public var expectedBytes: Int64
        /// What ``status``, ``bytesWritten`` and ``expectedBytes`` come from, unrounded, for
        /// ``DownloadsListing/downloadingFraction``.
        fileprivate var bytes: Bytes
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
        let expected = downloads.reduce(0.0) { $0 + $1.bytes.expected }
        guard expected > 0 else { return 0 }
        let written = downloads.reduce(0.0) { $0 + min($1.bytes.written, $1.bytes.expected) }
        return min(written / expected, 1)
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
        downloadedBytes = listed.reduce(0) { Self.adding($0, $1.byteCount) }
    }

    /// The row state of `record`, with its live `progress` if any.
    public static func status(of record: DownloadRecordDTO, progress: DownloadsController.Progress?) -> Status {
        status(of: record, bytes: Bytes(record, progress: progress))
    }

    private static func status(of record: DownloadRecordDTO, bytes: Bytes) -> Status {
        switch record.state {
        case .queued: .queued
        case .downloading: .downloading(bytes.fraction)
        case .paused: .paused(bytes.fraction)
        case .failed: .failed
        }
    }

    // MARK: - Building

    private static func item(_ item: LocalLibraryItemDTO) -> Item {
        Item(
            id: item.id, serverConnectionID: item.serverConnectionID, libraryItemId: item.libraryItemId,
            mediaType: item.mediaType, title: item.title, author: item.authorName, coverUpdatedAt: item.coverUpdatedAt,
            byteCount: item.files.reduce(0) { adding($0, max($1.size, 0)) },
            trackCount: item.files.count { $0.kind == .audio }, hasEbook: item.files.contains { $0.kind == .ebook },
            episodes: item.mediaType == .podcast ? episodes(of: item) : [])
    }

    /// The snapshot's episodes, plus any whose files have no entry in it.
    private static func episodes(of item: LocalLibraryItemDTO) -> [Episode] {
        var bytes: [String: Int64] = [:]
        var filenames: [String: String] = [:]
        for file in item.files {
            guard let id = file.episodeId else { continue }
            bytes[id] = adding(bytes[id] ?? 0, max(file.size, 0))
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

    /// An episode's record is titled by the episode (`DownloadPlanner`); its snapshot's metadata
    /// is the podcast's.
    private static func download(_ record: DownloadRecordDTO, progress: Progress?) -> Download {
        let episode = record.key.episodeId.map { id in record.media.episodes.first { $0.id == id }?.title ?? id }
        let bytes = Bytes(record, progress: progress)
        return Download(
            id: record.id, title: episode ?? record.title,
            subtitle: episode == nil ? nil : record.media.metadata.title,
            status: status(of: record, bytes: bytes),
            bytesWritten: wholeBytes(bytes.written), expectedBytes: wholeBytes(bytes.expected), bytes: bytes)
    }

    fileprivate typealias Progress = DownloadsController.Progress

    /// A download's bytes, written and expected, from which its row's fraction, its byte label
    /// and ``downloadingFraction`` all come. Summed as `Double`, as `DownloadManager` sums them.
    fileprivate struct Bytes: Sendable, Equatable {
        var written: Double
        var expected: Double

        /// The parts' stored bytes, or the live `progress`. Its fraction is `bytes` over the
        /// expected sizes the transfers have learned, which can differ from the stored ones, so
        /// that size is `bytes` over the fraction; while the fraction is 0 no size is known
        /// live, and the stored one stands.
        init(_ record: DownloadRecordDTO, progress: Progress?) {
            written = record.parts.reduce(0.0) { $0 + Double(max($1.bytesWritten, 0)) }
            expected = record.parts.reduce(0.0) { $0 + Double(max($1.expectedBytes, 0)) }
            guard let progress else { return }
            let live = Double(max(progress.bytes, 0))
            written = max(written, live)
            if progress.fraction >= 1 {
                expected = live
            } else if progress.fraction > 0 {
                expected = (live / progress.fraction).rounded()
            }
        }

        /// From 0 to 1; 0 while no size is known.
        var fraction: Double { expected > 0 ? min(written / expected, 1) : 0 }
    }

    /// `bytes` rounded to whole bytes, or `Int64.max` when that doesn't fit.
    private static func wholeBytes(_ bytes: Double) -> Int64 {
        bytes < 0x1p63 ? Int64(max(bytes, 0).rounded()) : .max
    }

    /// `a + b` of non-negative sizes, or `Int64.max` when that overflows.
    private static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : sum
    }

    private static func byTitle(_ lhs: Item, _ rhs: Item) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
