import ABSData
import Foundation

/// The download state of one book, or one podcast episode, for its Download button (#75, legacy
/// `index.vue`'s download button and `DownloadItem.vue`). A pure value, built from
/// ``DownloadsController``'s records and progress and the connection's stored local items.
///
/// - A download record of the media (not a cover-only one) wins: it is queued, downloading,
///   paused or failed, with the fraction ``DownloadsListing/status(of:progress:)`` computes.
/// - Without one, the media is downloaded when a local item of the server item has, for a book,
///   an audio or ebook file, or for an episode a file carrying its ID; the same rules
///   ``StoredDownloadStatus`` and `DownloadManager` use for `alreadyDownloaded`.
/// - Records and items of other connections, other server items, or (for a book) episodes don't
///   count.
public enum ItemDownloadState: Sendable, Equatable {
    /// Not downloaded and not queued.
    case none
    /// Waiting to start.
    case queued(recordID: UUID)
    /// With the fraction done, from 0 to 1.
    case downloading(recordID: UUID, fraction: Double)
    /// Stopped for now (for example in the background), with the fraction done.
    case paused(recordID: UUID, fraction: Double)
    /// Failed for good; the user retries or cancels it.
    case failed(recordID: UUID)
    /// Downloaded, as the local item with this ID.
    case downloaded(localItemID: UUID)

    /// - Parameters:
    ///   - libraryItemID: the server item.
    ///   - episodeID: the podcast episode, or `nil` for a book.
    ///   - connectionID: the server connection the item belongs to.
    ///   - records: ``DownloadsController/records``.
    ///   - progress: ``DownloadsController/progress``.
    ///   - localItems: the stored local items.
    public init(
        libraryItemID: String, episodeID: String?, connectionID: UUID, records: [DownloadRecordDTO],
        progress: [UUID: DownloadsController.Progress], localItems: [LocalLibraryItemDTO]
    ) {
        let key = MediaKey(serverConnectionID: connectionID, libraryItemId: libraryItemID, episodeId: episodeID)
        if let record = records.first(where: { $0.key == key && !$0.isCoverOnly }) {
            switch DownloadsListing.status(of: record, progress: progress[record.id]) {
            case .queued: self = .queued(recordID: record.id)
            case .downloading(let fraction): self = .downloading(recordID: record.id, fraction: fraction)
            case .paused(let fraction): self = .paused(recordID: record.id, fraction: fraction)
            case .failed: self = .failed(recordID: record.id)
            }
            return
        }
        let downloaded = localItems.first { item in
            item.serverConnectionID == connectionID && item.libraryItemId == libraryItemID
                && item.files.contains { file in
                    if let episodeID = key.episodeId { return file.episodeId == episodeID }
                    return file.kind == .audio || file.kind == .ebook
                }
        }
        self = downloaded.map { .downloaded(localItemID: $0.id) } ?? .none
    }

    /// Whether the book, or podcast episode, is downloaded on this device for `connectionID`, from
    /// the stored local items alone: the downloaded mark on cards and rows. Only completed
    /// downloads count (a local item exists once one completed); downloads under way don't, nor do
    /// other connections' items. For a podcast (`episodeID` `nil`), any downloaded episode counts,
    /// as legacy `LazyBookCard.vue`'s `showHasLocalDownload` does.
    public static func isDownloaded(
        libraryItemID: String, episodeID: String?, connectionID: UUID, localItems: [LocalLibraryItemDTO]
    ) -> Bool {
        ItemDownloadState(
            libraryItemID: libraryItemID, episodeID: episodeID, connectionID: connectionID, records: [],
            progress: [:], localItems: localItems
        ).localItemID != nil
    }

    /// The download record under way, which Cancel removes; `nil` when there's none.
    public var recordID: UUID? {
        switch self {
        case .queued(let id), .downloading(let id, _), .paused(let id, _), .failed(let id): id
        case .none, .downloaded: nil
        }
    }

    /// The local item a Delete removes; `nil` unless downloaded.
    public var localItemID: UUID? {
        if case .downloaded(let id) = self { id } else { nil }
    }

    /// The fraction done while downloading or paused, from 0 to 1; `nil` otherwise.
    public var fraction: Double? {
        switch self {
        case .downloading(_, let fraction), .paused(_, let fraction): min(max(fraction, 0), 1)
        case .none, .queued, .failed, .downloaded: nil
        }
    }

    /// Whether Download starts a new download: nothing is queued or downloaded yet.
    public var canStart: Bool { self == .none }

    /// Whether Retry applies: a paused or failed download, which a new request resumes.
    public var canRetry: Bool {
        switch self {
        case .paused, .failed: true
        case .none, .queued, .downloading, .downloaded: false
        }
    }
}
