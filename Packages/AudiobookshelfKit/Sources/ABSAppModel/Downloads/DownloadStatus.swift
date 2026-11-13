import ABSData
import Foundation

/// Which of a connection's library items need no new download: already downloaded, or with a
/// download record. ``StoredDownloadStatus`` reads the stores; tests use fakes.
public protocol DownloadStatusReading: Sendable {
    /// The library item IDs of `connectionID` that are downloaded (a local item with an audio or
    /// ebook file) or have a book download record in any state.
    func downloadedOrQueuedItemIDs(connectionID: UUID) async throws -> Set<String>
}

/// ``DownloadStatusReading`` on the app's ``LocalItemStore`` and ``DownloadStore``, with the same
/// rules ``DownloadManager`` uses to answer `alreadyDownloaded` and `alreadyQueued`. Cover-only
/// records and episode records don't count: they don't download the book.
public struct StoredDownloadStatus: DownloadStatusReading {
    private let localItems: LocalItemStore
    private let records: DownloadStore

    public init(localItems: LocalItemStore, records: DownloadStore) {
        self.localItems = localItems
        self.records = records
    }

    public func downloadedOrQueuedItemIDs(connectionID: UUID) async throws -> Set<String> {
        let downloaded = try await localItems.items(serverConnectionID: connectionID)
            .filter { item in item.files.contains { $0.kind == .audio || $0.kind == .ebook } }
            .map(\.libraryItemId)
        let queued = try await records.records(serverConnectionID: connectionID)
            .filter { !$0.isCoverOnly && $0.key.episodeId == nil }
            .map(\.key.libraryItemId)
        return Set(downloaded).union(queued)
    }
}
