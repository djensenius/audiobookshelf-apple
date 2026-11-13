import ABSCore
import ABSData
import ABSDownloads
import Foundation

/// What ``DownloadsController`` needs from ``DownloadManager``, so the controller can be tested
/// with a fake. ``DownloadManager`` conforms; see it for what each member means.
public protocol DownloadManaging: Sendable {
    /// See ``DownloadManager/events()``.
    func events() async -> AsyncStream<DownloadManagerEvent>
    /// See ``DownloadManager/enqueue(item:episodeID:connectionID:replacingExisting:unlessQuiescedSince:)``.
    func enqueue(
        item: LibraryItem, episodeID: String?, connectionID: UUID, replacingExisting: Bool,
        unlessQuiescedSince generation: Int?
    ) async throws(DownloadManagerError) -> DownloadManager.EnqueueResult
    /// See ``DownloadManager/quiesceGeneration()``.
    func quiesceGeneration() async -> Int
    /// See ``DownloadManager/restartActiveTransfers()``.
    func restartActiveTransfers() async throws(DownloadManagerError)
}

extension DownloadManager: DownloadManaging {}
