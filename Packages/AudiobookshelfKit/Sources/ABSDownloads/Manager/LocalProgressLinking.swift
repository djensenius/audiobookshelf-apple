import ABSData
import Foundation

/// Links local listening progress to downloaded media, so progress of downloaded media is kept
/// (`LocalProgressStore.pruneSynced()` only deletes rows without a download).
///
/// ``DownloadManager`` calls it when a download completes and when downloaded media is deleted.
/// ``LocalProgressStoreLinker`` implements it over `LocalProgressStore`; seeding local progress
/// comes with local playback (#74, decision Q4). Errors are logged; they never undo the download
/// or the deletion.
///
/// The manager makes these calls for one library item one at a time, holding the item, and
/// doesn't link media that a deletion through it removed first. A local item deleted
/// some other way (by `LocalItemStore` directly, such as with its connection) can still be
/// linked after it is gone, so an implementation must accept a link to a missing item.
public protocol LocalProgressLinking: Sendable {
    /// The media of `key` is now downloaded, as the local item `itemID`.
    func link(key: MediaKey, itemID: UUID) async throws
    /// The local item `itemID` was deleted with all its media.
    func detach(itemID: UUID) async throws
    /// One podcast episode of a local item was deleted; the item and its other episodes stay.
    func detach(key: MediaKey) async throws
}
