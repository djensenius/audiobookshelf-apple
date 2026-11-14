import ABSData
import Foundation
import Observation

/// A book or podcast episode waiting in the queue, with display metadata for queue readers.
public struct QueueItem: Sendable, Hashable, Codable, Identifiable {
    /// Identity is fixed so `episodeID` stays normalized; create a new item to change it.
    public let libraryItemID: String
    public let episodeID: String?
    public var title: String
    /// The author, or the podcast's title for an episode.
    public var subtitle: String?
    /// The cover is `coverPath` on `libraryItemID`.
    public var coverPath: String?
    /// Seconds, when known. Non-finite or negative values become `nil`, so the queue always
    /// encodes as JSON.
    public let duration: Double?

    public init(
        libraryItemID: String, episodeID: String? = nil, title: String, subtitle: String? = nil,
        coverPath: String? = nil, duration: Double? = nil
    ) {
        self.libraryItemID = libraryItemID
        self.episodeID = episodeID?.isEmpty == true ? nil : episodeID
        self.title = title
        self.subtitle = subtitle
        self.coverPath = coverPath
        self.duration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    enum CodingKeys: String, CodingKey {
        case libraryItemID, episodeID, title, subtitle, coverPath, duration
    }

    /// Normalizes an empty `episodeID` to `nil`, as the memberwise initializer does.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            libraryItemID: try container.decode(String.self, forKey: .libraryItemID),
            episodeID: try container.decodeIfPresent(String.self, forKey: .episodeID),
            title: try container.decode(String.self, forKey: .title),
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle),
            coverPath: try container.decodeIfPresent(String.self, forKey: .coverPath),
            duration: try container.decodeIfPresent(Double.self, forKey: .duration))
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
/// at most once: queueing it again moves it. The queue itself does not start playback or dequeue
/// on playback events; ``PlaybackQueueAdvancer`` does, and other callers mutate it explicitly.
@MainActor
@Observable
public final class PlaybackQueue: PlaybackQueueReading {
    public let serverConnectionID: UUID
    public private(set) var items: [QueueItem]

    @ObservationIgnored private let store: any PlaybackQueueStoring
    /// Called after every change; the attached ``PlaybackQueueAdvancer`` recomputes the next item.
    @ObservationIgnored var onItemsChange: (@MainActor () -> Void)?
    /// Set when its scope retires: the queue stays as saved, for the connection's next scope.
    @ObservationIgnored private var isRetired = false

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

    /// Replaces the whole queue with `items`, in one change; a media listed twice is queued once, where it is
    /// first listed.
    public func replace(with items: [QueueItem]) {
        var seen = Set<QueueItem.ID>()
        let unique = items.filter { seen.insert($0.id).inserted }
        update { $0 = unique }
    }

    /// Makes every later change a no-op, even through a reference kept from before.
    func retire() {
        isRetired = true
    }

    /// Applies `change` and saves the result when it differs, unless the queue has retired.
    private func update(_ change: (inout [QueueItem]) -> Void) {
        guard !isRetired else { return }
        var updated = items
        change(&updated)
        guard updated != items else { return }
        items = updated
        store.save(updated, serverConnectionID: serverConnectionID)
        onItemsChange?()
    }
}
