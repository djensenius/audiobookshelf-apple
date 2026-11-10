import ABSData
import Foundation
import Observation

/// A book or podcast episode waiting in the queue, with what the queue UI and CarPlay's Up Next
/// show for it.
public struct QueueItem: Sendable, Hashable, Codable, Identifiable {
    public var libraryItemID: String
    public var episodeID: String?
    public var title: String
    /// The author, or the podcast's title for an episode.
    public var subtitle: String?
    /// The cover is `coverPath` on `libraryItemID`.
    public var coverPath: String?
    /// Seconds, when known.
    public var duration: Double?

    public init(
        libraryItemID: String, episodeID: String? = nil, title: String, subtitle: String? = nil,
        coverPath: String? = nil, duration: Double? = nil
    ) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID?.isEmpty == true ? nil : episodeID
        self.title = title
        self.subtitle = subtitle
        self.coverPath = coverPath
        self.duration = duration
    }

    /// The media; the queue holds each media at most once.
    public var id: String { Self.id(libraryItemID: libraryItemID, episodeID: episodeID) }

    public func key(serverConnectionID: UUID) -> MediaKey {
        MediaKey(serverConnectionID: serverConnectionID, libraryItemId: libraryItemID, episodeId: episodeID)
    }

    static func id(libraryItemID: String, episodeID: String?) -> String {
        "\(libraryItemID)|\(episodeID ?? "")"
    }
}

/// A read-only, observable view of the queue, for CarPlay's Up Next and other readers that must
/// not change it. Reading ``items`` inside an observation scope tracks changes.
@MainActor
public protocol PlaybackQueueReading: AnyObject, Observable {
    var serverConnectionID: UUID { get }
    /// What plays next, in order.
    var items: [QueueItem] { get }
}

/// The user's play queue for one server connection, saved on every change. Each media is queued
/// at most once: queueing it again moves it. ``PlaybackQueueAdvancer`` plays from it when an item
/// ends, and removes an item once it becomes the current one.
@MainActor
@Observable
public final class PlaybackQueue: PlaybackQueueReading {
    public let serverConnectionID: UUID
    public private(set) var items: [QueueItem]

    @ObservationIgnored private let store: any PlaybackQueueStoring

    /// Loads the connection's saved queue from `store`.
    public init(serverConnectionID: UUID, store: any PlaybackQueueStoring) {
        self.serverConnectionID = serverConnectionID
        self.store = store
        items = store.load(serverConnectionID: serverConnectionID)
    }

    /// Puts `item` first, so it plays after the current one.
    public func playNext(_ item: QueueItem) {
        update { items in
            items.removeAll { $0.id == item.id }
            items.insert(item, at: 0)
        }
    }

    /// Puts `item` last.
    public func addToEnd(_ item: QueueItem) {
        update { items in
            items.removeAll { $0.id == item.id }
            items.append(item)
        }
    }

    public func remove(id: QueueItem.ID) {
        update { $0.removeAll { $0.id == id } }
    }

    /// Removes the media `key`, if it is queued on this connection.
    public func remove(_ key: MediaKey) {
        guard key.serverConnectionID == serverConnectionID else { return }
        remove(id: QueueItem.id(libraryItemID: key.libraryItemId, episodeID: key.episodeId))
    }

    public func remove(atOffsets offsets: IndexSet) {
        update { items in
            items = items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        }
    }

    /// Moves the items at `source` to just before the item at `destination` (`items.count` for
    /// the end), keeping their order, like SwiftUI's `onMove`.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { items in
            let source = source.filteredIndexSet { items.indices.contains($0) }
            let destination = min(max(destination, 0), items.count)
            let moving = source.map { items[$0] }
            let target = destination - source.count(where: { $0 < destination })
            items = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
            items.insert(contentsOf: moving, at: target)
        }
    }

    public func clear() {
        update { $0.removeAll() }
    }

    /// Applies `change` and saves the result when it differs.
    private func update(_ change: (inout [QueueItem]) -> Void) {
        var updated = items
        change(&updated)
        guard updated != items else { return }
        items = updated
        store.save(updated, serverConnectionID: serverConnectionID)
    }
}
