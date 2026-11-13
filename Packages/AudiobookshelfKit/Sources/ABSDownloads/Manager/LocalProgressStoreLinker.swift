import ABSData
import Foundation

/// ``LocalProgressLinking`` over `LocalProgressStore` (#74): a downloaded item's progress rows
/// carry its local item ID, so `LocalProgressStore.pruneSynced()` keeps them.
///
/// It only links rows that already exist. Media that was never played on this device has no
/// row, and a link to it does nothing: the row playback creates later records the local item
/// itself (`LocalProgressStore.recordEdit(_:for:serverProgress:localLibraryItemID:now:)`).
/// Seeding rows from server progress needs a server baseline, so it comes with local playback.
///
/// Unlinking leaves the row, so its unsynced changes still reach the server; a synced row is
/// pruned like any other.
public struct LocalProgressStoreLinker: LocalProgressLinking {
    private let store: LocalProgressStore

    /// - Parameter store: the app's one `LocalProgressStore`, the one playback writes with.
    public init(store: LocalProgressStore) {
        self.store = store
    }

    public func link(key: MediaKey, itemID: UUID) async throws {
        try await store.setLocalLibraryItemID(itemID, for: key)
    }

    public func detach(itemID: UUID) async throws {
        for row in try await store.progress(localLibraryItemID: itemID) {
            try await store.setLocalLibraryItemID(nil, for: row.key)
        }
    }

    public func detach(key: MediaKey) async throws {
        try await store.setLocalLibraryItemID(nil, for: key)
    }
}
