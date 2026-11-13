import ABSCore
import ABSData
import ABSDownloads
import Foundation

/// What the Downloads tab (``DownloadsTabModel``) needs from ``DownloadManager`` on top of
/// ``DownloadManaging``: cancelling and retrying downloads, and deleting downloaded media.
/// ``DownloadManager`` conforms; see it for what each member means.
public protocol DownloadControlling: DownloadManaging {
    /// See ``DownloadManager/cancel(recordID:)``.
    @discardableResult func cancel(recordID: UUID) async throws(DownloadManagerError) -> Bool
    /// See ``DownloadManager/retry(recordID:)``.
    @discardableResult func retry(recordID: UUID) async throws(DownloadManagerError) -> Bool
    /// See ``DownloadManager/deleteLocalItem(id:)``.
    @discardableResult func deleteLocalItem(id: UUID) async throws(DownloadManagerError) -> Bool
    /// See ``DownloadManager/deleteEpisode(itemID:episodeId:)``.
    @discardableResult func deleteEpisode(itemID: UUID, episodeId: String) async throws(DownloadManagerError) -> Bool
}

extension DownloadManager: DownloadControlling {}
