import ABSCore
import ABSPlayback
import Foundation

/// One row of the queue sheet (#156): a queued item's text, duration and cover, on the
/// connection whose queue it's in.
public struct QueueRow: Identifiable, Hashable, Sendable {
    public let id: QueueItem.ID
    public let libraryItemID: String
    public let episodeID: String?
    public let title: String
    /// The author, or the podcast's title for an episode; `nil` when there's none.
    public let subtitle: String?
    /// Seconds; `nil` when unknown or zero.
    public let duration: Double?
    /// `nil` when the item has no cover, like the player's.
    public let coverKey: ImageKey?

    /// Episodes have square covers.
    public var isPodcastEpisode: Bool { episodeID != nil }

    public init(item: QueueItem, serverConnectionID: UUID) {
        id = item.id
        libraryItemID = item.libraryItemID
        episodeID = item.episodeID
        title = item.title
        subtitle = PlayerDisplayInfo.nonEmpty(item.subtitle)
        duration = item.duration.flatMap { $0 > 0 ? $0 : nil }
        coverKey = PlayerDisplayInfo.coverKey(
            key: item.key(serverConnectionID: serverConnectionID), path: item.coverPath, updatedAt: nil)
    }

    /// The rows of `queue`, in play order. Reading it inside an observation scope tracks the queue.
    @MainActor
    public static func rows(of queue: some PlaybackQueueReading) -> [QueueRow] {
        queue.items.map { QueueRow(item: $0, serverConnectionID: queue.serverConnectionID) }
    }

    /// Plays the row's media from its saved progress. The scope's advancer takes it out of the
    /// queue once its session starts, so a play that fails leaves it queued.
    @MainActor
    public func play(with play: PlayItemAction) async throws {
        try await play(itemID: libraryItemID, episodeID: episodeID)
    }
}
