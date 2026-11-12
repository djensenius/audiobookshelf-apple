import ABSData
import Foundation

/// What ``DownloadManager/events()`` reports.
public enum DownloadManagerEvent: Sendable, Equatable {
    /// A record was created or changed: queued, resumed, or a part completed or failed.
    case recordChanged(DownloadRecordDTO)
    /// A record's live progress across all its parts, at most about once a second per record
    /// (and always when it reaches the end). `fraction` is `bytes` over the parts' expected
    /// sizes, from 0 to 1, and 0 while no size is known.
    case progress(recordID: UUID, fraction: Double, bytes: Int64)
    /// Every part finished: the record is now the local item `itemID`, and was deleted.
    case completed(recordID: UUID, itemID: UUID, key: MediaKey)
    /// A part failed for good, so its record is now `failed`. Nothing retries it on its own;
    /// the user does.
    case failed(recordID: UUID, code: DownloadFailureCode, message: String)
    /// The record is gone and left no downloaded media: it was cancelled
    /// (``DownloadManager/cancel(recordID:)``), or what it completed into (the local item, or
    /// the episode) was deleted before its completion was reported, or it only fetched an item's
    /// cover again (``DownloadRecordDTO/isCoverOnly``). No other event follows for it. Deleted
    /// local items aren't reported: the UI observes them.
    case recordRemoved(recordID: UUID)
}

/// Why a ``DownloadManager`` call, such as
/// ``DownloadManager/enqueue(item:episodeID:connectionID:replacingExisting:)``, failed.
public enum DownloadManagerError: Error, Equatable, Sendable {
    /// An episode was asked for, but the item isn't a podcast.
    case notPodcast
    /// The podcast has no episode with the requested ID, or no episode was asked for.
    case episodeNotFound
    /// The item has nothing to download.
    case noDownloadableMedia
    /// A file can't be named or located on the server, or the item isn't expanded.
    case missingFileMetadata
    /// The item's media type is unknown to this client.
    case unknownMediaType
    /// The item or episode ID can't be used as a folder name.
    case invalidIdentifier(String)
    /// The download, plus ``DownloadManager/storageHeadroom``, needs more bytes than are
    /// available.
    case insufficientStorage(required: Int64, available: Int64)
    /// The server connection doesn't exist (it was removed).
    case connectionNotFound(UUID)
    /// The downloads couldn't be read or saved.
    case storeFailure

    init(_ error: DownloadPlanError) {
        switch error {
        case .notPodcast: self = .notPodcast
        case .episodeNotFound: self = .episodeNotFound
        case .noDownloadableMedia: self = .noDownloadableMedia
        case .missingFileMetadata: self = .missingFileMetadata
        case .unknownMediaType: self = .unknownMediaType
        case .invalidIdentifier(let id): self = .invalidIdentifier(id)
        }
    }
}
