import ABSData
import Foundation

/// Links local listening progress to downloaded media, so progress of downloaded media is kept
/// (`LocalProgressStore.pruneSynced()` only deletes rows without a download).
///
/// ``DownloadManager`` calls it when a download completes and when downloaded media is deleted.
/// Its implementation over `LocalProgressStore.setLocalLibraryItemID(_:for:)`, and the seeding of
/// local progress, arrive with #74 (decision Q4). Errors are logged; they never undo the download
/// or the deletion.
public protocol LocalProgressLinking: Sendable {
    /// The media of `key` is now downloaded, as the local item `itemID`.
    func link(key: MediaKey, itemID: UUID) async throws
    /// The local item `itemID` was deleted with all its media.
    func detach(itemID: UUID) async throws
    /// One podcast episode of a local item was deleted; the item and its other episodes stay.
    func detach(key: MediaKey) async throws
}
